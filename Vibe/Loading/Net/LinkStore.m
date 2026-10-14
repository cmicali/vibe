//
//  LinkStore.m
//  Vibe
//

#import "LinkStore.h"

#include <sys/stat.h>

#import "AudioTrack.h"
#import "HTTPTransferClientInternal.h"
#import "FilePaths.h"
#import "PlaceholderFiles.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"
#import "RemotePlaceholderStoreInternal.h"
#import "VibeStrings.h"

NSErrorDomain const VibeLinkErrorDomain = @"com.commonwealthrecordings.Vibe.Link";

// On every link directory: the link's record (recordOfLink:…). On the
// directory, because a placeholder's attributes are as unreadable as its
// bytes.
static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.link";
// Enough for every signature VibeLinkAudioExtension knows.
static const uint64_t kProbeBytes = 16;

static NSString *_Nullable VibeLinkString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSError *VibeLinkMakeError(VibeLinkError code, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSUnderlyingErrorKey] = underlying;
    info[VibeHTTPErrorStatusCodeKey] = underlying.userInfo[VibeHTTPErrorStatusCodeKey];
    return [NSError errorWithDomain:VibeLinkErrorDomain code:code userInfo:info];
}

// The probe's failure as the link's. An iCloud lookup's refusal already is.
static NSError *VibeLinkErrorOfProbe(NSError *error, NSString *_Nullable host) {
    VibeLinkError code;
    if ([error.domain isEqualToString:VibeLinkErrorDomain]) {
        return error;
    }
    if ([error.domain isEqualToString:VibeHTTPErrorDomain] && error.code == VibeHTTPErrorStatus) {
        code = VibeLinkErrorOfStatus([error.userInfo[VibeHTTPErrorStatusCodeKey] integerValue]);
    }
    else if ([error.domain isEqualToString:VibeHTTPErrorDomain] && error.code == VibeHTTPErrorRefusedURL) {
        // Only a redirect can be refused here: the link itself passed.
        code = VibeLinkErrorInsecure;
    }
    else {
        code = VibeLinkErrorOfNetworkError(error, host);
    }
    return VibeLinkMakeError(code, error);
}

// The file's mtime as seconds since 1970: an iCloud lookup's, else the
// metadata's Last-Modified (RFC 9110's IMF-fixdate), else `fallback`.
static time_t VibeLinkModificationTime(NSDictionary *_Nullable metadata, NSTimeInterval fallback) {
    id modified = metadata[@"modified"];
    if ([modified isKindOfClass:NSNumber.class] && [modified longLongValue] >= 0) {
        return (time_t)[modified longLongValue];
    }
    NSString *text = VibeLinkString(metadata[@"lastModified"]);
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    });
    NSDate *date = text.length > 0 ? [formatter dateFromString:text] : nil;
    time_t seconds = date ? (time_t)date.timeIntervalSince1970 : -1;
    return seconds >= 0 ? seconds : (time_t)fallback;
}

#pragma mark - Store

@implementation LinkStore

+ (LinkStore *)shared {
    static LinkStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        // Fail fast offline: a waiting request holds a materialization lane.
        configuration.waitsForConnectivity = NO;
        // The store keeps the bytes. A cached answer could name another
        // version than the server's.
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        LinkClient *client = [[LinkClient alloc] initWithConfiguration:configuration];
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:NULL];
        shared = [[LinkStore alloc] initWithClient:client
                                           rootURL:[support URLByAppendingPathComponent:@"Links" isDirectory:YES]];
    });
    return shared;
}

- (instancetype)initWithClient:(LinkClient *)client rootURL:(NSURL *)rootURL {
    self = [super initWithClient:client rootURL:rootURL indexAttribute:kIndexAttribute
                  downloadBudget:kVibeLinkDownloadBudgetBytes];
    if (self) {
        _probeTimeoutScale = 1;
        // Every request and every redirect: a redirect can leave the local
        // network, and a stub cannot test App Transport Security.
        client.allowsURL = ^BOOL(NSURL *from, NSURL *url) {
            return VibeLinkRequestIsAllowed(from, url);
        };
    }
    return self;
}

#pragma mark - The record

- (NSURL *)directoryOfLink:(NSURL *)link {
    return [self.rootURL URLByAppendingPathComponent:VibeLinkDirectoryName(link) isDirectory:YES];
}

// The one file a link's directory holds, placeholder or download. Its part
// file is hidden.
- (nullable NSURL *)fileInDirectory:(NSURL *)directory {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:NULL];
    for (NSURL *entry in entries) {
        struct stat st;
        if (lstat(entry.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) {
            return entry;
        }
    }
    return nil;
}

// {url, etag, lastModified, version, size, modified, contentType, ranges,
// host, opened}: what the probe or the download answered, the mtime the file
// takes, whether the server reads by range, and when the link was last
// opened. A header the answer lacked is left out.
- (NSMutableDictionary *)recordOfLink:(NSURL *)link
                             metadata:(NSDictionary *)metadata
                               ranges:(BOOL)ranges
                             modified:(time_t)modified
                               opened:(NSTimeInterval)opened {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"url"] = link.absoluteString;
    record[@"etag"] = VibeLinkString(metadata[@"etag"]);
    record[@"lastModified"] = VibeLinkString(metadata[@"lastModified"]);
    record[@"version"] = [self.client versionOfMetadata:metadata];
    record[@"size"] = @([self.client sizeOfMetadata:metadata]);
    record[@"modified"] = @(modified);
    record[@"contentType"] = VibeLinkString(metadata[@"contentType"]);
    record[@"ranges"] = @(ranges);
    record[@"host"] = link.host.lowercaseString;
    record[@"opened"] = @(opened);
    return record;
}

// Whether an answer is of the file the record describes, a checked record
// (recordOfDirectory:): the same size, and the record's version. Under
// another ETag, the same Last-Modified will do (the CDN case). A record with
// no version matches on its size alone.
- (BOOL)record:(NSDictionary *)record matchesMetadata:(NSDictionary *)metadata {
    int64_t size = [self.client sizeOfMetadata:metadata];
    NSNumber *recorded = record[@"size"];
    if (size < 0 || size != recorded.longLongValue) {
        return NO;
    }
    NSString *version = record[@"version"];
    if (!version || [[self.client versionOfMetadata:metadata] isEqualToString:version]) {
        return YES;
    }
    if ([self.client isSameFileUnderAnotherETag:metadata asMetadata:record]) {
        LogInfo(@"Links: %@ answered another ETag with the same size and date (version %@, now %@)",
                record[@"host"], version, [self.client versionOfMetadata:metadata]);
        return YES;
    }
    return NO;
}

// The directory's record, nil for none. The xattr is read from disk, so a
// record whose fields are not what recordOfLink:… writes counts as none.
- (nullable NSDictionary *)recordOfDirectory:(NSURL *)directory {
    NSDictionary *record = [self indexOfDirectory:directory];
    if (!VibeLinkString(record[@"url"])) {
        return nil;
    }
    for (NSString *key in @[@"size", @"modified", @"ranges", @"opened"]) {
        if (![record[key] isKindOfClass:NSNumber.class]) {
            return nil;
        }
    }
    for (NSString *key in @[@"etag", @"lastModified", @"version", @"contentType", @"host"]) {
        if (record[key] && !VibeLinkString(record[key])) {
            return nil;
        }
    }
    return record;
}

- (void)touchRecord:(NSDictionary *)record ofDirectory:(NSURL *)directory ranges:(nullable NSNumber *)ranges {
    NSMutableDictionary *touched = [record mutableCopy];
    touched[@"opened"] = @(NSDate.date.timeIntervalSince1970);
    if (ranges != nil) {
        touched[@"ranges"] = ranges;
    }
    [self writeIndex:touched ofDirectory:directory];
}

- (nullable NSString *)hostOfLinkFileURL:(NSURL *)url {
    NSString *host = [self containsURL:url] ? [self recordOfDirectory:url.URLByDeletingLastPathComponent][@"host"] : nil;
    return host.length > 0 ? host : nil;
}

#pragma mark - Hooks

- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    NSString *link = [self recordOfDirectory:url.URLByDeletingLastPathComponent][@"url"];
    NSURL *target = link ? [NSURL URLWithString:link] : nil;
    return target ?: [super remoteTargetForURL:url error:error];
}

- (BOOL)readsByRangeAtURL:(NSURL *)url {
    return [[self recordOfDirectory:url.URLByDeletingLastPathComponent][@"ranges"] boolValue];
}

// A tag read of a file the record no longer describes would parse another
// file's tags as this one's.
- (dispatch_block_t)readTarget:(id)target
                         ofURL:(NSURL *)url
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    return [super readTarget:target ofURL:url offset:offset length:length
                  completion:^(NSData *data, NSDictionary *metadata, NSError *error) {
        NSDictionary *record = [self recordOfDirectory:directory];
        if (data && record && ![self record:record matchesMetadata:metadata]) {
            LogWarn(@"Links: a read of %@ answered another file than its record's (version %@, now %@)",
                    record[@"host"], record[@"version"], [self.client versionOfMetadata:metadata]);
            completion(nil, nil, [self.client errorWithCode:VibeHTTPErrorVersionChanged
                                                description:@"the link's file changed since it was opened"]);
            return;
        }
        completion(data, metadata, error);
    }];
}

// TRAP: the placeholder's mtime is the record's, and the cache key is made
// from it, so the install keeps it while the download is the record's file.
// A download of another version, which a link changed since its open
// fetches, takes its own Last-Modified, and the record follows it. A record
// left describing other bytes would evict the download at the next open, or
// fail its tag reads.
- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    __block time_t modified = -1;
    // TRAP: a sync from the client's delivery queue onto the disk queue.
    // Nothing on the disk queue may wait on the client, or the two deadlock.
    dispatch_sync(self.diskQueue, ^{
        NSDictionary *record = [self recordOfDirectory:directory];
        if (record && [self record:record matchesMetadata:metadata]) {
            modified = (time_t)[record[@"modified"] longLongValue];
            return;
        }
        modified = VibeLinkModificationTime(metadata, NSDate.date.timeIntervalSince1970);
        if (record) {
            NSURL *link = [NSURL URLWithString:record[@"url"]];
            NSMutableDictionary *followed = [self recordOfLink:link metadata:metadata
                                                        ranges:[record[@"ranges"] boolValue] modified:modified
                                                        opened:[record[@"opened"] doubleValue]];
            LogInfo(@"Links: downloaded another version of %@ than its record's (version %@, now %@)",
                    record[@"host"], record[@"version"], followed[@"version"]);
            [self writeIndex:followed ofDirectory:directory];
        }
    });
    return modified;
}

- (NSString *)logName {
    return @"Links";
}

#pragma mark - Resolve

- (dispatch_block_t)resolveURLString:(NSString *)string completion:(void (^)(NSURL *, NSError *))completion {
    // Main only, so a cancel on main settles the resolve before it returns.
    __block BOOL settled = NO;
    void (^settle)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        if (!settled) {
            settled = YES;
            completion(file, error);
        }
    };
    void (^finish)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            settle(file, error);
        });
    };
    NSError *cancelled = VibeLinkMakeError(VibeLinkErrorCancelled, nil);
    NSURL *typed = VibeLinkURLFromString(string);
    VibeLinkError refused = VibeLinkURLAcceptance(typed);
    if (refused != VibeLinkErrorNone) {
        LogInfo(@"Links: refused a link (%ld)", (long)refused);
        finish(nil, VibeLinkMakeError(refused, nil));
        return ^{
            settle(nil, cancelled);
        };
    }
    NSDictionary<NSString *, NSString *> *folder = VibeDropboxFolderLinkToken(typed);
    NSURL *folderLink = folder ? VibeDropboxFolderLinkURL(folder) : nil;
    NSURL *link = folderLink ?: VibeLinkDirectDownloadURL(typed);
    NSTimeInterval timeout = VibeLinkProbeTimeout(link.host) * self.probeTimeoutScale;
    // The disk queue's: the first of the answer, the deadline, and the cancel
    // wins. The others do nothing.
    __block BOOL answered = NO;
    dispatch_block_t stop = nil;
    if (folderLink) {
        // No deadline of the probe's kind: a large folder takes many
        // requests. Each has the probe's length as its idle timeout.
        stop = [(LinkClient *)self.client listDropboxFolder:folder timeout:timeout
                                                 completion:^(NSString *name, NSArray<NSDictionary *> *files,
                                                              NSError *error) {
            dispatch_async(self.diskQueue, ^{
                if (answered) {
                    return;
                }
                answered = YES;
                NSError *failure = nil;
                NSURL *file = error ? [self downloadOfLink:link afterProbeError:error failure:&failure]
                                    : [self settleFolderLink:link name:name files:files error:&failure];
                finish(file, file ? nil : failure);
            });
        }];
    }
    else {
        NSTimeInterval probed = NSDate.date.timeIntervalSince1970;
        stop = [self.client probeTarget:link length:kProbeBytes
                             completion:^(NSDictionary *metadata, NSHTTPURLResponse *response,
                                          NSData *head, NSError *error) {
            dispatch_async(self.diskQueue, ^{
                if (answered) {
                    return;
                }
                answered = YES;
                NSError *failure = nil;
                NSURL *file = error ? [self downloadOfLink:link afterProbeError:error failure:&failure]
                                    : [self settleLink:link metadata:metadata response:response head:head
                                              probedAt:probed error:&failure];
                finish(file, file ? nil : failure);
            });
        }];
        dispatch_block_t cancelProbe = stop;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self.diskQueue, ^{
            if (answered) {
                return;
            }
            answered = YES;
            cancelProbe();
            LogInfo(@"Links: %@ sent nothing within %.0f s", link.host, timeout);
            // The host's network failure, as a connection's own timeout would be.
            NSError *timedOut = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
            NSError *failure = nil;
            NSURL *file = [self downloadOfLink:link afterProbeError:timedOut failure:&failure];
            finish(file, file ? nil : failure);
        });
    }
    return ^{
        if (settled) {
            return;
        }
        stop();
        dispatch_async(self.diskQueue, ^{
            answered = YES;
        });
        LogInfo(@"Links: cancelled the open of %@", link.host);
        settle(nil, cancelled);
    };
}

// The disk queue. A link that cannot be reached still opens its download. A
// folder link opens its playlist, which names its downloads.
- (nullable NSURL *)downloadOfLink:(NSURL *)link afterProbeError:(NSError *)error failure:(NSError **)failure {
    NSError *linkError = VibeLinkErrorOfProbe(error, link.host);
    if (failure) *failure = linkError;
    if (linkError.code != VibeLinkErrorUnreachable && linkError.code != VibeLinkErrorLocalNetwork) {
        LogInfo(@"Links: %@ did not open: %ld (%@)", link.host, (long)linkError.code, error.localizedDescription);
        return nil;
    }
    NSURL *directory = [self directoryOfLink:link];
    NSDictionary *record = [self recordOfDirectory:directory];
    NSURL *file = record ? [self fileInDirectory:directory] : nil;
    struct stat st;
    if (!file || lstat(file.fileSystemRepresentation, &st) != 0 || VibeFileModeIsRemotePlaceholder(st.st_mode)) {
        LogInfo(@"Links: %@ is unreachable: %@", link.host, error.localizedDescription);
        return nil;
    }
    LogInfo(@"Links: %@ is unreachable; opening its download", link.host);
    [self touchRecord:record ofDirectory:directory ranges:nil];
    return file;
}

// The disk queue. The probe's answer as the link's record and file.
- (nullable NSURL *)settleLink:(NSURL *)link
                      metadata:(NSDictionary *)metadata
                      response:(NSHTTPURLResponse *)response
                          head:(NSData *)head
                      probedAt:(NSTimeInterval)probed
                         error:(NSError **)error {
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    NSString *disposition = VibeLinkString(metadata[@"contentDisposition"]);
    // The link's own URL, not the redirect's: a CDN's path carries no name.
    // Not audio outranks no size. A sign-in page is often sent with no length.
    NSString *extension = VibeLinkAudioExtension(head ?: [NSData data], link, disposition,
                                                 VibeLinkString(metadata[@"contentType"]), playable);
    if (!extension) {
        if (error) *error = VibeLinkMakeError(VibeLinkErrorNotAudio, nil);
        LogInfo(@"Links: %@ is not audio (%@)", link.host, metadata[@"contentType"]);
        return nil;
    }
    int64_t size = [self.client sizeOfMetadata:metadata];
    if (size < 0) {
        VibeLinkError code = VibeLinkErrorOfMissingSize(response.allHeaderFields);
        if (error) *error = VibeLinkMakeError(code, nil);
        LogInfo(@"Links: %@ states no size (%ld)", link.host, (long)code);
        return nil;
    }
    NSURL *directory = [self directoryOfLink:link];
    [self prepareRoot];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil
                                                      error:error]) {
        return nil;
    }
    BOOL ranges = response.statusCode == 206;
    NSDictionary *record = [self recordOfDirectory:directory];
    NSURL *existing = record ? [self fileInDirectory:directory] : nil;
    // No version proves nothing: a link without one is fetched again. A file
    // of another size or mtime than the record's is a placeholder the record
    // moved past while it streamed.
    struct stat st;
    BOOL current = existing && lstat(existing.fileSystemRepresentation, &st) == 0
            && st.st_size == [record[@"size"] longLongValue] && st.st_mtimespec.tv_sec == [record[@"modified"] longLongValue];
    if (current && record[@"version"] && [self record:record matchesMetadata:metadata]) {
        [self touchRecord:record ofDirectory:directory ranges:@(ranges)];
        LogInfo(@"Links: %@ is unchanged; reusing %@", link.host, existing.lastPathComponent);
        return existing;
    }
    time_t modified = VibeLinkModificationTime(metadata, probed);
    NSDictionary *fresh = [self recordOfLink:link metadata:metadata ranges:ranges modified:modified opened:probed];
    NSURL *file = [self placeFileNamed:VibeLinkFileName(link, disposition, extension, playable) inDirectory:directory
                              existing:existing record:fresh error:error];
    if (file) {
        LogInfo(@"Links: %@ %@ as %@, %lld bytes, %@", link.host, existing ? @"changed" : @"opened",
                file.lastPathComponent, size, ranges ? @"by range" : @"whole only");
    }
    return file;
}

// The disk queue. The record's file in its directory: a fresh placeholder
// named `name`, of the record's size and mtime. The file the directory held
// goes, with its part, unless it has that name.
// TRAP: a file being fetched now keeps its placeholder, from the fetch's
// start, before its first response. The fetch's install renames the bytes it
// downloaded over whatever stands at the URL, and its readers hold the part
// file. A new name would leave that install a second file. Only the record
// changes, and the install's mtime hook sets it back to what was downloaded.
- (nullable NSURL *)placeFileNamed:(NSString *)name
                       inDirectory:(NSURL *)directory
                          existing:(nullable NSURL *)existing
                            record:(NSDictionary *)record
                             error:(NSError **)error {
    if (existing && [self isFetchingURL:existing]) {
        LogInfo(@"Links: %@ changed while it is fetched; updating its record only", record[@"host"]);
        [self writeIndex:record ofDirectory:directory];
        return existing;
    }
    NSURL *file = [directory URLByAppendingPathComponent:name isDirectory:NO];
    if (existing && ![existing.lastPathComponent isEqualToString:name]) {
        [NSFileManager.defaultManager removeItemAtURL:existing error:NULL];
        [NSFileManager.defaultManager removeItemAtURL:[PlaceholderFiles remotePlaceholderPartURL:existing] error:NULL];
    }
    if (![LinkStore writePlaceholderAtURL:file size:[record[@"size"] longLongValue]
                                 modified:(time_t)[record[@"modified"] longLongValue]]) {
        int failure = errno;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        LogWarn(@"Links: could not write the placeholder for %@: %s", record[@"host"], strerror(failure));
        return nil;
    }
    [self writeIndex:record ofDirectory:directory];
    return file;
}

#pragma mark - Folders

// The disk queue. A folder's listing as its link's directory: a directory per
// audio file under it, and the playlist naming them in the listing's order.
// The playlist is the directory's one file, so pruning and the offline open
// treat the folder as one link.
- (nullable NSURL *)settleFolderLink:(NSURL *)link
                                name:(nullable NSString *)name
                               files:(NSArray<NSDictionary *> *)files
                               error:(NSError **)error {
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    NSMutableArray<NSDictionary *> *audio = [NSMutableArray array];
    for (NSDictionary *entry in files) {
        if ([playable containsObject:[entry[@"name"] pathExtension].lowercaseString]) {
            [audio addObject:entry];
        }
    }
    if (audio.count == 0) {
        if (error) *error = VibeLinkMakeError(VibeLinkErrorNotAudio, nil);
        LogInfo(@"Links: %@ lists no audio among %lu files", link.host, (unsigned long)files.count);
        return nil;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directory = [self directoryOfLink:link];
    [self prepareRoot];
    if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    NSTimeInterval opened = NSDate.date.timeIntervalSince1970;
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *kept = [NSMutableSet set];
    for (NSDictionary *entry in audio) {
        NSString *fileDirectoryName = VibeLinkDirectoryName(entry[@"url"]);
        if ([kept containsObject:fileDirectoryName]) {
            continue;
        }
        NSURL *file = [self placeFolderFile:entry
                                inDirectory:[directory URLByAppendingPathComponent:fileDirectoryName isDirectory:YES]
                                  extension:[entry[@"name"] pathExtension].lowercaseString opened:opened error:error];
        if (!file) {
            return nil;
        }
        [kept addObject:fileDirectoryName];
        [tracks addObject:[[AudioTrack alloc] initWithURL:file]];
    }
    // A file that left the folder goes, with its download, unless a fetch of
    // it runs now.
    BOOL removed = NO;
    for (NSURL *entry in [manager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL]) {
        struct stat st;
        if (lstat(entry.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)
                || [kept containsObject:entry.lastPathComponent]) {
            continue;
        }
        NSURL *gone = [self fileInDirectory:entry];
        if (!(gone && [self isFetchingURL:gone])) {
            [manager removeItemAtURL:entry error:NULL];
            removed = YES;
        }
    }
    if (removed) {
        [self forgetCachedIndexes];
    }
    NSString *playlistName = VibeLinkCleanedFileName(name.length > 0 ? name : @"Dropbox", @"m3u8", playable);
    NSURL *playlist = [directory URLByAppendingPathComponent:playlistName isDirectory:NO];
    NSURL *renamed = [self fileInDirectory:directory];
    if (renamed && ![renamed.lastPathComponent isEqualToString:playlistName]) {
        [manager removeItemAtURL:renamed error:NULL];
    }
    if (![PlaylistFile writeM3UForTracks:tracks relativeToDirectory:directory toURL:playlist error:error]) {
        LogWarn(@"Links: could not write the playlist for %@", link.host);
        return nil;
    }
    [self writeIndex:[self recordOfLink:link metadata:@{} ranges:NO modified:0 opened:opened] ofDirectory:directory];
    LogInfo(@"Links: %@ opened a folder of %lu files as %@", link.host, (unsigned long)tracks.count, playlistName);
    return playlist;
}

// The disk queue. One listed file in its own directory under its folder's.
// The listing's size, and its ts when it states one, are the file's version.
// The same ones keep the file, placeholder or download. Without a ts the
// record's mtime stays while the size does. The record has no version, so a
// download and a tag read check it by its size alone. A range is assumed, as
// Dropbox's content host answers one (DropboxLinkRules.h).
- (nullable NSURL *)placeFolderFile:(NSDictionary *)entry
                        inDirectory:(NSURL *)directory
                          extension:(NSString *)extension
                             opened:(NSTimeInterval)opened
                              error:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil
                                                      error:error]) {
        return nil;
    }
    long long size = [entry[@"size"] longLongValue];
    NSNumber *listed = entry[@"modified"];
    NSDictionary *record = [self recordOfDirectory:directory];
    NSURL *existing = record ? [self fileInDirectory:directory] : nil;
    BOOL sameSize = record && [record[@"size"] longLongValue] == size;
    time_t modified = listed ? (time_t)listed.longLongValue
                             : sameSize ? (time_t)[record[@"modified"] longLongValue] : (time_t)opened;
    struct stat st;
    if (sameSize && [record[@"modified"] longLongValue] == modified && existing
            && lstat(existing.fileSystemRepresentation, &st) == 0 && st.st_size == size
            && st.st_mtimespec.tv_sec == modified) {
        [self touchRecord:record ofDirectory:directory ranges:nil];
        return existing;
    }
    NSDictionary *fresh = [self recordOfLink:entry[@"url"] metadata:@{@"size": @(size)} ranges:YES modified:modified
                                      opened:opened];
    return [self placeFileNamed:VibeLinkCleanedFileName(entry[@"name"], extension, PlayableExtensions.lookup)
                    inDirectory:directory existing:existing record:fresh error:error];
}

#pragma mark - Messages

+ (NSString *)messageForError:(NSError *)error brief:(BOOL)brief {
    if (![error.domain isEqualToString:VibeLinkErrorDomain]) {
        return brief ? STR_LINK_STATUS_UNREACHABLE : STR_LINK_ERROR_UNREACHABLE;
    }
    switch ((VibeLinkError)error.code) {
        case VibeLinkErrorInvalid:      return brief ? STR_LINK_STATUS_INVALID : STR_LINK_ERROR_INVALID;
        case VibeLinkErrorInsecure:     return brief ? STR_LINK_STATUS_INSECURE : STR_LINK_ERROR_INSECURE;
        case VibeLinkErrorLocalNetwork: return brief ? STR_LINK_STATUS_LOCAL_NETWORK : STR_LINK_ERROR_LOCAL_NETWORK;
        case VibeLinkErrorNotFound:     return brief ? STR_LINK_STATUS_NOT_FOUND : STR_LINK_ERROR_NOT_FOUND;
        case VibeLinkErrorDenied:       return brief ? STR_LINK_STATUS_DENIED : STR_LINK_ERROR_DENIED;
        case VibeLinkErrorNotAudio:     return brief ? STR_LINK_STATUS_NOT_AUDIO : STR_LINK_ERROR_NOT_AUDIO;
        case VibeLinkErrorNoSize:       return brief ? STR_LINK_STATUS_NO_SIZE : STR_LINK_ERROR_NO_SIZE;
        case VibeLinkErrorLiveStream:   return brief ? STR_LINK_STATUS_LIVE_STREAM : STR_LINK_ERROR_LIVE_STREAM;
        case VibeLinkErrorServer:
            return [NSString stringWithFormat:brief ? STR_LINK_STATUS_SERVER : STR_LINK_ERROR_SERVER,
                                              (long)[error.userInfo[VibeHTTPErrorStatusCodeKey] integerValue]];
        case VibeLinkErrorICloudPrivate:
            return brief ? STR_LINK_STATUS_ICLOUD_PRIVATE : STR_LINK_ERROR_ICLOUD_PRIVATE;
        case VibeLinkErrorICloudFolder: return brief ? STR_LINK_STATUS_ICLOUD_FOLDER : STR_LINK_ERROR_ICLOUD_FOLDER;
        case VibeLinkErrorICloudUnreadable:
            return brief ? STR_LINK_STATUS_ICLOUD_UNREADABLE : STR_LINK_ERROR_ICLOUD_UNREADABLE;
        case VibeLinkErrorCancelled:    return nil;
        case VibeLinkErrorNone:
        case VibeLinkErrorUnreachable:
            break;
    }
    return brief ? STR_LINK_STATUS_UNREACHABLE : STR_LINK_ERROR_UNREACHABLE;
}

#pragma mark - Pruning

- (void)pruneKeepingTracks:(NSArray<AudioTrack *> *)tracks recentURLs:(NSArray<NSURL *> *)recents {
    dispatch_async(self.diskQueue, ^{
        NSArray<NSURL *> *directories = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.rootURL
                                                                    includingPropertiesForKeys:nil
                                                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                         error:NULL];
        // Most launches hold no link, and need not look at the playlist.
        if (directories.count == 0) {
            return;
        }
        // A kept URL names its link by the component below the root.
        NSUInteger depth = VibeComparablePath(self.rootURL.path).pathComponents.count;
        NSMutableSet<NSString *> *keptNames = [NSMutableSet set];
        void (^keep)(NSURL *) = ^(NSURL *url) {
            if (![self containsURL:url]) {
                return;
            }
            NSArray<NSString *> *components = VibeComparablePath(url.path).pathComponents;
            if (components.count > depth) {
                [keptNames addObject:components[depth]];
            }
        };
        for (AudioTrack *track in tracks) {
            keep(track.url);
        }
        for (NSURL *url in recents) {
            keep(url);
        }
        NSMutableDictionary<NSString *, id> *records = [NSMutableDictionary dictionary];
        for (NSURL *directory in directories) {
            struct stat st;
            if (lstat(directory.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                records[directory.lastPathComponent] = [self recordOfDirectory:directory] ?: NSNull.null;
            }
        }
        NSArray<NSString *> *pruned = VibeLinkDirectoriesToPrune(records, keptNames, NSDate.date.timeIntervalSince1970);
        for (NSString *name in pruned) {
            [NSFileManager.defaultManager removeItemAtURL:[self.rootURL URLByAppendingPathComponent:name isDirectory:YES]
                                                    error:NULL];
        }
        if (pruned.count > 0) {
            [self forgetCachedIndexes];
            LogInfo(@"Links: pruned %lu of %lu links, unopened for 30 days", (unsigned long)pruned.count,
                    (unsigned long)records.count);
        }
    });
}

@end
