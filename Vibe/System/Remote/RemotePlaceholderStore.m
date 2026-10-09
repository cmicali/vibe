//
//  RemotePlaceholderStore.m
//  Vibe
//

#import "RemotePlaceholderStoreInternal.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>

#import "AudioFileOpenRules.h"
#import "CloudFileMaterializer.h"
#import "HTTPTransferClientInternal.h"
#import "NSURLUtil.h"
#import "PlaylistFile.h"

// A ranged read slower than this is given up, so a stalled request cannot
// hold a parse worker; the parse fails and a later scan retries it.
static const NSTimeInterval kRangedReadTimeout = 30;
// A fetch reports its file readable once this much of its head is on disk.
// An anti-stutter knob, not a correctness requirement: a reader past the
// bytes written waits for them regardless.
static const uint64_t kStreamReadableBytes = 256 * 1024;
// A tag read of a file streaming now waits this long for a range its stream
// is about to hold, its first MB or its tail window, before asking the
// server: the current track's parse starts at the tap, beside the download,
// so its bytes arrive about one first byte later either way (1–1.7 s
// measured on Dropbox).
static const NSTimeInterval kStreamedTagWaitSeconds = 3;
static const uint64_t kStreamedTagHeadBytes = 1024 * 1024;

static NSError *VibePOSIXError(void) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

BOOL VibeWritePlaceholder(NSURL *url, long long size, time_t modified) {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSURL *temp = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.vibe-placeholder", url.lastPathComponent]];
    unlink(temp.fileSystemRepresentation);
    int fd = open(temp.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        return NO;
    }
    struct timeval times[2] = {{modified, 0}, {modified, 0}};
    BOOL made = ftruncate(fd, size) == 0 && futimes(fd, times) == 0 && fchmod(fd, 0) == 0;
    close(fd);
    struct stat st;
    if (made && lstat(url.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
    if (!made || rename(temp.fileSystemRepresentation, url.fileSystemRepresentation) != 0) {
        unlink(temp.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

BOOL VibeInstallPart(NSURL *part, NSURL *url, time_t modified, NSError **error) {
    if (chmod(part.fileSystemRepresentation, 0644) != 0) {
        if (error) *error = VibePOSIXError();
        unlink(part.fileSystemRepresentation);
        return NO;
    }
    if (modified >= 0) {
        struct timeval times[2] = {{modified, 0}, {modified, 0}};
        utimes(part.fileSystemRepresentation, times);
    }
    if (rename(part.fileSystemRepresentation, url.fileSystemRepresentation) != 0) {
        if (error) *error = VibePOSIXError();
        unlink(part.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

@implementation RemotePlaceholderStore {
    NSString *_indexAttribute;
    // Written on main, read on the disk queue.
    long long _downloadBudget;
    // Parsed directory indexes by path, NSNull for "none"; a ranged read asks
    // for one per block. Every write replaces its entry.
    NSCache<NSString *, id> *_indexes;
    // Each fetch's availability while its transfer writes the part file, by
    // the file's comparable path; removed only once finished. _fetching holds
    // the same keys from the fetch's start, before its first response makes
    // the availability, to its end; both under the condition, broadcast at
    // each of those three edges, which a tag read waits on.
    NSCondition *_streamsCondition;
    NSMutableDictionary<NSString *, CloudFileAvailability *> *_streams;
    NSMutableSet<NSString *> *_fetching;
}

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget {
    self = [super init];
    if (self) {
        _client = client;
        _rootURL = [rootURL copy];
        _indexAttribute = [indexAttribute copy];
        _downloadBudget = downloadBudget;
        _indexes = [[NSCache alloc] init];
        _streamsCondition = [[NSCondition alloc] init];
        _streams = [NSMutableDictionary dictionary];
        _fetching = [NSMutableSet set];
        NSString *label = [NSString stringWithFormat:@"com.commonwealthrecordings.Vibe.%@-store",
                           self.logName.lowercaseString];
        _diskQueue = dispatch_queue_create(label.UTF8String,
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (void)installAsRemoteBackend {
    [CloudFileMaterializer setRemoteRoot:_rootURL
                                   fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                               void (^onCancel)(dispatch_block_t), NSError **error) {
        return [self fetchPlaceholderAtURL:url onReadable:onReadable onCancel:onCancel error:error];
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return [self readPlaceholderAtURL:url offset:offset length:length error:error];
    } availability:^CloudFileAvailability *(NSURL *url) {
        return [self availabilityForURL:url];
    }];
}

#pragma mark - Hooks

- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
    return nil;
}

- (dispatch_block_t)downloadTarget:(id)target
                             toURL:(NSURL *)destination
                          progress:(void (^)(uint64_t, int64_t, NSString *))progress
                        completion:(void (^)(NSDictionary *, NSError *))completion {
    return [_client downloadTarget:target toURL:destination progress:progress completion:completion];
}

- (dispatch_block_t)readTarget:(id)target
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    return [_client readTarget:target offset:offset length:length completion:completion];
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    return [_client versionOfMetadata:metadata];
}

- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0 ? st.st_mtimespec.tv_sec : -1;
}

- (BOOL)readsByRangeAtURL:(NSURL *)url {
    return YES;
}

- (NSURL *)budgetRootURL {
    return _rootURL;
}

- (void)downloadsDidChangeWithTotal:(long long)total {
}

- (NSString *)logName {
    return @"Remote";
}

#pragma mark - The index

// Keyed by the comparable spelling: a write through /var and a read through
// /private/var are one directory.
- (NSDictionary *)indexOfDirectory:(NSURL *)directory {
    return [self indexOfDirectory:directory key:VibeComparablePath(directory.path)];
}

- (NSDictionary *)indexOfDirectory:(NSURL *)directory key:(NSString *)key {
    id cached = [_indexes objectForKey:key];
    if (cached) {
        return cached == NSNull.null ? nil : cached;
    }
    NSDictionary *index = nil;
    const char *path = directory.fileSystemRepresentation;
    const char *name = _indexAttribute.UTF8String;
    ssize_t size = getxattr(path, name, NULL, 0, 0, XATTR_NOFOLLOW);
    if (size > 0) {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        if (getxattr(path, name, data.mutableBytes, (size_t)size, 0, XATTR_NOFOLLOW) == size) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            index = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        }
    }
    [_indexes setObject:index ?: NSNull.null forKey:key];
    return index;
}

// Unchanged indexes are not rewritten: every visit relists its folder.
- (void)writeIndex:(NSDictionary *)index ofDirectory:(NSURL *)directory {
    NSString *key = VibeComparablePath(directory.path);
    if ([[self indexOfDirectory:directory key:key] isEqualToDictionary:index]) {
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:index options:0 error:NULL];
    if (setxattr(directory.fileSystemRepresentation, _indexAttribute.UTF8String, data.bytes, data.length, 0,
                 XATTR_NOFOLLOW) != 0) {
        LogWarn(@"%@: could not index %@: %s", self.logName, directory.lastPathComponent, strerror(errno));
        [_indexes removeObjectForKey:key];
        return;
    }
    [_indexes setObject:index forKey:key];
}

- (void)forgetCachedIndexes {
    [_indexes removeAllObjects];
}

#pragma mark - Downloads (the disk queue)

- (dispatch_block_t)downloadTarget:(id)target
                   installingAtURL:(NSURL *)url
                          progress:(void (^)(uint64_t, int64_t, NSString *))progress
                        completion:(void (^)(NSError *))completion {
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:url];
    return [self downloadTarget:target toURL:part progress:progress completion:^(NSDictionary *metadata,
                                                                                 NSError *error) {
        NSError *installError = nil;
        if (!error && !VibeInstallPart(part, url, [self modificationTimeOfMetadata:metadata forURL:url],
                                       &installError)) {
            error = installError;
        }
        completion(error);
    }];
}

- (NSArray<NSDictionary *> *)downloadsUnder:(NSURL *)root {
    NSMutableArray<NSDictionary *> *downloads = [NSMutableArray array];
    NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
            enumeratorAtURL:root
 includingPropertiesForKeys:nil
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:nil];
    for (NSURL *url in walk) {
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)
                || VibeFileModeIsRemotePlaceholder(st.st_mode)
                || [PlaylistFile isPlaylistExtension:url.pathExtension.lowercaseString]) {
            continue;
        }
        [downloads addObject:@{@"url": url, @"size": @(st.st_size), @"modified": @(st.st_mtimespec.tv_sec),
                               @"downloaded": @(st.st_birthtimespec.tv_sec + st.st_birthtimespec.tv_nsec / 1e9)}];
    }
    [downloads sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"downloaded"] compare:b[@"downloaded"]];
    }];
    return downloads;
}

// Size and mtime are kept, so the cache key, and with it the cached tags and
// waveform, still match when the song is downloaded again.
- (BOOL)evictDownload:(NSDictionary *)download {
    return VibeWritePlaceholder(download[@"url"], [download[@"size"] longLongValue],
                                (time_t)[download[@"modified"] longLongValue]);
}

// Oldest first, never the one just fetched: it is about to be opened.
- (long long)enforceDownloadBudgetKeeping:(NSURL *)keep {
    NSURL *root = self.budgetRootURL;
    if (!root) {
        return 0;
    }
    NSArray<NSDictionary *> *downloads = [self downloadsUnder:root];
    long long total = 0;
    for (NSDictionary *download in downloads) {
        total += [download[@"size"] longLongValue];
    }
    NSString *kept = VibeComparablePath(keep.path);
    for (NSDictionary *download in downloads) {
        if (total <= self.downloadBudget) {
            break;
        }
        if ([VibeComparablePath([download[@"url"] path]) isEqualToString:kept]) {
            continue;
        }
        if ([self evictDownload:download]) {
            total -= [download[@"size"] longLongValue];
            LogInfo(@"%@: over budget, %@ back to a placeholder", self.logName,
                    [download[@"url"] lastPathComponent]);
        }
    }
    return total;
}

- (long long)downloadBudget {
    return __atomic_load_n(&_downloadBudget, __ATOMIC_RELAXED);
}

// Applied on the disk queue as a fetch's landing applies it: a smaller
// budget sends the oldest back to placeholders at once, and the new total is
// reported. A song playing from one keeps its open file.
- (void)setDownloadBudget:(long long)downloadBudget {
    __atomic_store_n(&_downloadBudget, downloadBudget, __ATOMIC_RELAXED);
    dispatch_async(_diskQueue, ^{
        [self downloadsDidChangeWithTotal:[self enforceDownloadBudgetKeeping:nil]];
    });
}

- (void)measureDownloadsWithCompletion:(void (^)(long long))completion {
    dispatch_async(_diskQueue, ^{
        NSURL *root = self.budgetRootURL;
        long long total = 0;
        for (NSDictionary *download in root ? [self downloadsUnder:root] : @[]) {
            total += [download[@"size"] longLongValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(total);
        });
    });
}

- (void)removeDownloadsWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_diskQueue, ^{
        NSURL *root = self.budgetRootURL;
        NSUInteger removed = 0;
        long long kept = 0;
        for (NSDictionary *download in root ? [self downloadsUnder:root] : @[]) {
            if ([self evictDownload:download]) {
                removed++;
            }
            else {
                kept += [download[@"size"] longLongValue];
            }
        }
        LogInfo(@"%@: removed %lu downloads", self.logName, (unsigned long)removed);
        [self downloadsDidChangeWithTotal:kept];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Ranged reads

- (NSData *)streamedBytesOfURL:(NSURL *)url at:(uint64_t)offset length:(uint64_t)length {
    NSString *key = VibeComparablePath(url.path);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kStreamedTagWaitSeconds];
    [_streamsCondition lock];
    CloudFileAvailability *stream = _streams[key];
    while (!stream && [_fetching containsObject:key] && [_streamsCondition waitUntilDate:deadline]) {
        stream = _streams[key];
    }
    [_streamsCondition unlock];
    if (!stream) {
        return nil;
    }
    uint64_t window = VibeAudioFileTailWindowBytes(url.pathExtension, stream.size);
    if (offset + length <= kStreamedTagHeadBytes || (window > 0 && offset >= stream.size - window)) {
        [stream waitForBytesAt:offset length:length windowInto:NULL capacity:0 copied:NULL interrupted:nil
                      deadline:deadline error:NULL];
    }
    return [stream readyBytesAt:offset length:length];
}

- (NSData *)readPlaceholderAtURL:(NSURL *)url
                          offset:(uint64_t)offset
                          length:(uint64_t)length
                           error:(NSError **)error {
    id target = [self remoteTargetForURL:url error:error];
    if (!target) {
        return nil;
    }
    if (length == 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return nil;
    }
    NSData *held = [self streamedBytesOfURL:url at:offset length:length];
    if (held.length == length) {
        return held;
    }
    if (![self readsByRangeAtURL:url]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:nil];
        return nil;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *bytes = nil;
    __block NSError *failure = nil;
    dispatch_block_t cancel = [self readTarget:target offset:offset + held.length length:length - held.length
                                    completion:^(NSData *data, NSDictionary *metadata, NSError *readError) {
        bytes = data;
        failure = readError;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kRangedReadTimeout * NSEC_PER_SEC))) != 0) {
        cancel();
        // The cancel completes the read; its answer is the timeout's.
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        return nil;
    }
    if (!bytes && error) {
        *error = failure;
    }
    if (bytes && held.length > 0) {
        NSMutableData *joined = [held mutableCopy];
        [joined appendData:bytes];
        bytes = joined;
    }
    return bytes;
}

#pragma mark - Fetch

// One ranged read of a file's last `window` bytes, on the call session, so it
// never queues behind a download's writes; `landed` gets the bytes and the
// version they are of, or nil and nil on a failure. A failure is not the
// transfer's: the window stays absent, and reads there wait for the download.
- (dispatch_block_t)readTailOfTarget:(id)target
                                size:(uint64_t)size
                              window:(uint64_t)window
                                name:(NSString *)name
                              landed:(void (^)(NSData *_Nullable bytes, NSString *_Nullable version))landed {
    NSError *cancelled = [_client errorWithCode:VibeHTTPErrorCancelled description:@"cancelled"];
    return [self readTarget:target offset:size - window length:window
                 completion:^(NSData *data, NSDictionary *metadata, NSError *error) {
        if (data.length == window) {
            landed(data, [self versionOfMetadata:metadata]);
            return;
        }
        if (!([error.domain isEqualToString:cancelled.domain] && error.code == cancelled.code)) {
            LogWarn(@"%@: no tail window for %@ (%lu bytes): %@", self.logName, name, (unsigned long)data.length,
                    error.localizedDescription);
        }
        landed(nil, nil);
    }];
}

// The tail read's bytes, once the download's first response is in too, by
// the rule fetchPlaceholderAtURL: states. Nil bytes, a failure already
// logged, or no stream (a response naming no size) install nothing.
- (void)installTail:(NSData *)bytes
            version:(NSString *)version
               into:(CloudFileAvailability *)stream
      pinnedVersion:(NSString *)pinned
         listedSize:(uint64_t)listed
               name:(NSString *)name
              since:(CFAbsoluteTime)start {
    if (!bytes || !stream) {
        return;
    }
    if (version.length == 0 || ![version isEqualToString:pinned] || stream.size != listed) {
        LogWarn(@"%@: dropped the tail window for %@: version %@ of %llu bytes, the download's version %@ of %llu",
                self.logName, name, version, listed, pinned, stream.size);
        return;
    }
    [stream installWindow:bytes atOffset:listed - bytes.length];
    LogInfo(@"%@: tail window for %@ at %.2fs into the fetch, %llu of %llu bytes downloaded by then", self.logName,
            name, CFAbsoluteTimeGetCurrent() - start, stream.writtenBytes, stream.size);
}

- (CloudFileAvailability *)availabilityForURL:(NSURL *)url {
    NSString *key = VibeComparablePath(url.path);
    [_streamsCondition lock];
    CloudFileAvailability *availability = _streams[key];
    [_streamsCondition unlock];
    return availability;
}

- (BOOL)fetchPlaceholderAtURL:(NSURL *)url
                   onReadable:(dispatch_block_t)onReadable
                     onCancel:(void (^)(dispatch_block_t))onCancel
                        error:(NSError **)error {
    id target = [self remoteTargetForURL:url error:error];
    if (!target) {
        return NO;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:url];
    NSString *key = VibeComparablePath(url.path);
    NSString *name = url.lastPathComponent;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    // The client's delivery queue's, and the completion runs after its last
    // progress call. The size is the response's, not the placeholder's: a
    // file changed since its placeholder was written is downloaded as it is
    // now.
    __block CloudFileAvailability *stream = nil;
    __block BOOL readable = NO;
    // TRAP: the tail read starts beside the download, by the same target, so
    // it lands about when the head does instead of a round trip after it; but
    // a read of the target answers whatever version is current when it is
    // served. Its window is installed only by whichever of the two answers
    // lands second, only when both name the same version and the download's
    // size is the placeholder's its offset came from; a missing version on
    // either side drops it. Installed unchecked, another version's tail would
    // decode as this one's. Under _streamsCondition: what each side knew when
    // the other landed.
    struct stat listing;
    uint64_t listed = stat(url.fileSystemRepresentation, &listing) == 0 ? (uint64_t)listing.st_size : 0;
    uint64_t window = [self readsByRangeAtURL:url] ? VibeAudioFileTailWindowBytes(url.pathExtension, listed) : 0;
    __block BOOL headKnown = NO;
    __block NSString *headVersion = nil;
    __block NSData *tailBytes = nil;
    __block NSString *tailVersion = nil;
    [_streamsCondition lock];
    [_fetching addObject:key];
    [_streamsCondition unlock];
    dispatch_block_t cancelTail = window == 0 ? nil
            : [self readTailOfTarget:target size:listed window:window name:name
                              landed:^(NSData *bytes, NSString *version) {
        [self->_streamsCondition lock];
        BOOL settle = headKnown;
        if (!settle) {
            tailBytes = bytes;
            tailVersion = version;
        }
        CloudFileAvailability *into = stream;
        NSString *pinned = headVersion;
        [self->_streamsCondition unlock];
        if (settle) {
            [self installTail:bytes version:version into:into pinnedVersion:pinned listedSize:listed name:name
                        since:start];
        }
    }];
    onCancel([self downloadTarget:target installingAtURL:url
                         progress:^(uint64_t written, int64_t size, NSString *version) {
        if (!headKnown) {
            // No size to read against: it downloads whole, as a provider's does.
            CloudFileAvailability *made = size < 0 ? nil
                    : [[CloudFileAvailability alloc] initWithPartURL:part size:(uint64_t)size];
            [self->_streamsCondition lock];
            if (made) {
                self->_streams[key] = made;
            }
            stream = made;
            headKnown = YES;
            headVersion = version;
            [self->_streamsCondition broadcast];
            NSData *bytes = tailBytes;
            NSString *landedVersion = tailVersion;
            tailBytes = nil;
            [self->_streamsCondition unlock];
            [self installTail:bytes version:landedVersion into:made pinnedVersion:version listedSize:listed
                         name:name since:start];
        }
        if (!stream) {
            return;
        }
        [stream noteWrittenBytes:written];
        if (onReadable && !readable && written >= kStreamReadableBytes && written < stream.size) {
            readable = YES;
            LogInfo(@"%@: %@ readable at %llu of %llu bytes, %.2fs into the fetch", self.logName, name,
                    written, stream.size, CFAbsoluteTimeGetCurrent() - start);
            onReadable();
        }
    } completion:^(NSError *downloadError) {
        failure = downloadError;
        if (cancelTail) {
            cancelTail();
        }
        // TRAP: finished after the install and before the lookup forgets it.
        // A reader whose part open missed the rename waits for the finish,
        // then opens url; one looking it up next opens url, the whole file.
        // A failure's part is deleted, or kept for the next fetch to continue
        // when the link ended the transfer (HTTPTransferClient); either way
        // that same wait turns into the failure, never a missing file or a
        // short read.
        [stream finishWithError:downloadError];
        [self->_streamsCondition lock];
        if (stream && self->_streams[key] == stream) {
            [self->_streams removeObjectForKey:key];
        }
        [self->_fetching removeObject:key];
        [self->_streamsCondition broadcast];
        [self->_streamsCondition unlock];
        dispatch_semaphore_signal(done);
    }]);
    // The client always completes: its request timeout bounds a stall.
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (failure) {
        if (error) *error = failure;
        return NO;
    }
    LogInfo(@"%@: downloaded %@ in %.1fs", self.logName, name, CFAbsoluteTimeGetCurrent() - start);
    dispatch_async(_diskQueue, ^{
        [self downloadsDidChangeWithTotal:[self enforceDownloadBudgetKeeping:url]];
    });
    return YES;
}

@end
