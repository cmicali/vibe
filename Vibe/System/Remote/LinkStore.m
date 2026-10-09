//
//  LinkStore.m
//  Vibe
//

#import "LinkStore.h"

#include <sys/stat.h>

#import "HTTPTransferClientInternal.h"
#import "NSURLUtil.h"
#import "PlayableExtensions.h"
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

static NSError *VibeLinkMakeError(VibeLinkError code, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSUnderlyingErrorKey] = underlying;
    info[VibeHTTPErrorStatusCodeKey] = underlying.userInfo[VibeHTTPErrorStatusCodeKey];
    return [NSError errorWithDomain:VibeLinkErrorDomain code:code userInfo:info];
}

// The probe's failure as the link's. A status the session did not take as
// a file is the server's, 2xx included.
static NSError *VibeLinkErrorOfProbe(NSError *error, NSString *_Nullable host) {
    VibeLinkError code;
    if ([error.domain isEqualToString:VibeHTTPErrorDomain] && error.code == VibeHTTPErrorStatus) {
        code = VibeLinkErrorOfStatus([error.userInfo[VibeHTTPErrorStatusCodeKey] integerValue]);
        if (code == VibeLinkErrorNone) {
            code = VibeLinkErrorServer;
        }
    }
    else if ([error.domain isEqualToString:VibeHTTPErrorDomain] && error.code == VibeHTTPErrorRefusedURL) {
        // Only a redirect can be refused here: the link itself passed.
        code = VibeLinkErrorInsecure;
    }
    else {
        code = VibeLinkErrorOfNetworkError(error, host);
        if (code == VibeLinkErrorNone) {
            code = VibeLinkErrorUnreachable;
        }
    }
    return VibeLinkMakeError(code, error);
}

// The metadata's Last-Modified (RFC 9110's IMF-fixdate) as seconds since
// 1970, `fallback` when it has none.
static time_t VibeLinkModificationTime(NSDictionary *_Nullable metadata, NSTimeInterval fallback) {
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
        HTTPTransferClient *client = [[HTTPTransferClient alloc] initWithConfiguration:configuration];
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

- (instancetype)initWithClient:(HTTPTransferClient *)client rootURL:(NSURL *)rootURL {
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
    record[@"version"] = [self versionOfMetadata:metadata];
    record[@"size"] = @([self.client sizeOfMetadata:metadata]);
    record[@"modified"] = @(modified);
    record[@"contentType"] = VibeLinkString(metadata[@"contentType"]);
    record[@"ranges"] = @(ranges);
    record[@"host"] = link.host.lowercaseString;
    record[@"opened"] = @(opened);
    return record;
}

// Whether an answer is of the file the record describes, a checked record
// (recordOfDirectory:): the same size, and the record's version. Under another ETag, the same Last-Modified will do
// (the CDN case, VibeHTTPIsSameFileUnderAnotherETag). A record with no
// version matches on its size alone.
- (BOOL)record:(NSDictionary *)record matchesMetadata:(NSDictionary *)metadata {
    int64_t size = [self.client sizeOfMetadata:metadata];
    NSNumber *recorded = record[@"size"];
    if (size < 0 || size != recorded.longLongValue) {
        return NO;
    }
    NSString *version = record[@"version"];
    if (!version || [[self versionOfMetadata:metadata] isEqualToString:version]) {
        return YES;
    }
    if (VibeHTTPIsSameFileUnderAnotherETag(recorded.longLongValue, record[@"lastModified"], size,
                                           VibeLinkString(metadata[@"lastModified"]))) {
        LogInfo(@"Links: %@ answered another ETag with the same size and date (version %@, now %@)",
                record[@"host"], version, [self versionOfMetadata:metadata]);
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

- (nullable NSDictionary *)recordOfLinkFileURL:(NSURL *)url {
    return [self containsURL:url] ? [self recordOfDirectory:url.URLByDeletingLastPathComponent] : nil;
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
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    NSURL *directory = [self directoryOfLink:target];
    return [super readTarget:target offset:offset length:length
                  completion:^(NSData *data, NSDictionary *metadata, NSError *error) {
        NSDictionary *record = [self recordOfDirectory:directory];
        if (data && record && ![self record:record matchesMetadata:metadata]) {
            LogWarn(@"Links: a read of %@ answered another file than its record's (version %@, now %@)",
                    record[@"host"], record[@"version"], [self versionOfMetadata:metadata]);
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
    NSURL *link = VibeLinkDirectDownloadURL(typed);
    NSTimeInterval probed = NSDate.date.timeIntervalSince1970;
    // The disk queue's: the first of the answer, the deadline, and the cancel
    // wins. The others do nothing.
    __block BOOL answered = NO;
    dispatch_block_t cancelProbe = [self.client probeTarget:link length:kProbeBytes
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
    NSTimeInterval timeout = VibeLinkProbeTimeout(link.host) * self.probeTimeoutScale;
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
    return ^{
        if (settled) {
            return;
        }
        cancelProbe();
        dispatch_async(self.diskQueue, ^{
            answered = YES;
        });
        LogInfo(@"Links: cancelled the open of %@", link.host);
        settle(nil, cancelled);
    };
}

// The disk queue. A link that cannot be reached still opens its download.
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
    // TRAP: a file streaming now keeps its placeholder. The fetch's install
    // renames the bytes it downloaded over whatever stands at the URL, and
    // its readers hold the part file. Only the record changes, and the
    // install's mtime hook sets it back to what was downloaded.
    if (existing && [self availabilityForURL:existing]) {
        LogInfo(@"Links: %@ changed while it streams; updating its record only", link.host);
        [self writeIndex:fresh ofDirectory:directory];
        return existing;
    }
    NSURL *file = [directory URLByAppendingPathComponent:VibeLinkFileName(link, disposition, extension, playable) isDirectory:NO];
    if (existing && ![existing.lastPathComponent isEqualToString:file.lastPathComponent]) {
        [NSFileManager.defaultManager removeItemAtURL:existing error:NULL];
        [NSFileManager.defaultManager removeItemAtURL:[NSURLUtil remotePlaceholderPartURL:existing] error:NULL];
    }
    if (![LinkStore writePlaceholderAtURL:file size:size modified:modified]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        LogWarn(@"Links: could not write the placeholder for %@: %s", link.host, strerror(errno));
        return nil;
    }
    [self writeIndex:fresh ofDirectory:directory];
    LogInfo(@"Links: %@ %@ as %@, %lld bytes, %@", existing ? @"changed; replaced" : @"opened", link.host,
            file.lastPathComponent, size, ranges ? @"by range" : @"whole only");
    return file;
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
        case VibeLinkErrorCancelled:    return nil;
        case VibeLinkErrorNone:
        case VibeLinkErrorUnreachable:
            break;
    }
    return brief ? STR_LINK_STATUS_UNREACHABLE : STR_LINK_ERROR_UNREACHABLE;
}

#pragma mark - Pruning

- (void)pruneKeepingURLs:(NSSet<NSURL *> *)kept {
    dispatch_async(self.diskQueue, ^{
        // A kept URL names its link by the component below the root.
        NSUInteger depth = VibeComparablePath(self.rootURL.path).pathComponents.count;
        NSMutableSet<NSString *> *keptNames = [NSMutableSet set];
        for (NSURL *url in kept) {
            NSArray<NSString *> *components = VibeComparablePath(url.path).pathComponents;
            if ([self containsURL:url] && components.count > depth) {
                [keptNames addObject:components[depth]];
            }
        }
        NSMutableDictionary<NSString *, id> *records = [NSMutableDictionary dictionary];
        NSArray<NSURL *> *directories = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.rootURL
                                                                    includingPropertiesForKeys:nil
                                                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                         error:NULL];
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
