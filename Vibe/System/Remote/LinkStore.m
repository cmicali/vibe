//
//  LinkStore.m
//  Vibe
//

#import "LinkStore.h"

#include <os/lock.h>
#include <sys/stat.h>

#import "AudioTrack.h"
#import "HTTPTransferClientInternal.h"
#import "ICloudLinkRules.h"
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

#pragma mark - Client

// A transfer's state: the lookup its attempt was sent with, a refused one
// still to be replaced, and the lookup that replaced one. A refusal of that
// last one fails.
static NSString *const kStateLookup = @"lookup";
static NSString *const kStateStaleLookup = @"staleLookup";
static NSString *const kStateRefreshedLookup = @"refreshedLookup";

@implementation LinkClient {
    os_unfair_lock _lookupLock;
    // Each share's last lookup, by its short GUID, with `lookedUp`: when it
    // was sent. Under the lock.
    NSMutableDictionary<NSString *, NSDictionary *> *_lookups;
    // The lookup claim: each share's waiters while its lookup is in flight.
    // Under the lock.
    NSMutableDictionary<NSString *, NSMutableArray *> *_lookupWaiters;
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _lookupLock = OS_UNFAIR_LOCK_INIT;
        _lookups = [NSMutableDictionary dictionary];
        _lookupWaiters = [NSMutableDictionary dictionary];
    }
    return self;
}

// A lookup the old sessions answered names that server's addresses. The
// base's init calls this before the ivars are set, so the lock is still
// zero, its initial value.
- (void)useSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    [super useSessionConfiguration:configuration];
    os_unfair_lock_lock(&_lookupLock);
    [_lookups removeAllObjects];
    os_unfair_lock_unlock(&_lookupLock);
}

// The share's file: the last lookup while it is fresh and is not `stale`,
// else a new one. Single-flight: a caller arriving during a lookup waits on
// that one. Any thread.
- (void)lookUpShortGUID:(NSString *)shortGUID
                 unlike:(nullable NSDictionary *)stale
             completion:(void (^)(NSDictionary *_Nullable file, NSError *_Nullable error))completion {
    os_unfair_lock_lock(&_lookupLock);
    NSDictionary *last = _lookups[shortGUID];
    if (last && last != stale
            && VibeICloudLinkAddressIsFresh([last[@"lookedUp"] doubleValue], [last[@"expiry"] doubleValue],
                                            NSDate.date.timeIntervalSince1970)) {
        os_unfair_lock_unlock(&_lookupLock);
        completion(last, nil);
        return;
    }
    NSMutableArray *waiters = _lookupWaiters[shortGUID];
    BOOL owner = waiters == nil;
    if (owner) {
        waiters = _lookupWaiters[shortGUID] = [NSMutableArray array];
    }
    [waiters addObject:[completion copy]];
    os_unfair_lock_unlock(&_lookupLock);
    if (!owner) {
        return;
    }
    [self sendLookupOfShortGUID:shortGUID completion:^(NSDictionary *file, NSError *error) {
        os_unfair_lock_lock(&self->_lookupLock);
        NSArray *settled = self->_lookupWaiters[shortGUID];
        [self->_lookupWaiters removeObjectForKey:shortGUID];
        if (file) {
            self->_lookups[shortGUID] = file;
        }
        os_unfair_lock_unlock(&self->_lookupLock);
        for (void (^waiter)(NSDictionary *, NSError *) in settled) {
            waiter(file, error);
        }
    }];
}

// A network failure passes through as itself: a download keeps its part,
// and a probe fails as unreachable. A status fails as the server's. Any
// answer that is not one file shared with anyone fails with its link error.
- (void)sendLookupOfShortGUID:(NSString *)shortGUID
                   completion:(void (^)(NSDictionary *_Nullable file, NSError *_Nullable error))completion {
    NSURL *url = [NSURL URLWithString:kVibeICloudLinkLookupURL];
    BOOL (^allows)(NSURL *, NSURL *) = self.allowsURL;
    if (allows && !allows(nil, url)) {
        completion(nil, [self errorWithCode:VibeHTTPErrorRefusedURL description:@"the address is not allowed"]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.icloud.com" forHTTPHeaderField:@"Origin"];
    request.HTTPBody = VibeICloudLinkLookupBody(shortGUID);
    NSTimeInterval sent = NSDate.date.timeIntervalSince1970;
    [[self.callSession dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            LogInfo(@"Links: the iCloud lookup failed: %@", error.localizedDescription);
            completion(nil, error);
            return;
        }
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status != 200) {
            LogWarn(@"Links: the iCloud lookup answered HTTP %ld", (long)status);
            completion(nil, [NSError errorWithDomain:VibeHTTPErrorDomain code:VibeHTTPErrorStatus
                                            userInfo:@{VibeHTTPErrorStatusCodeKey: @(status)}]);
            return;
        }
        id answer = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *file = nil;
        VibeLinkError refusal = VibeICloudLinkFileOfLookup(answer, &file);
        if (refusal != VibeLinkErrorNone) {
            LogInfo(@"Links: the iCloud lookup opens nothing (%ld)", (long)refusal);
            completion(nil, VibeLinkMakeError(refusal, nil));
            return;
        }
        NSMutableDictionary *looked = [file mutableCopy];
        looked[@"lookedUp"] = @(sent);
        NSTimeInterval expiry = [file[@"expiry"] doubleValue];
        LogInfo(@"Links: looked up an iCloud file of %@ bytes, its address valid for %.0f s", file[@"size"],
                expiry > 0 ? expiry - sent : -1);
        completion(looked, nil);
    }] resume];
}

// An iCloud share's request is its file's signed address, looked up first.
// The base adds the Range. A transfer waiting on the lookup is settled at
// once by its cancel (HTTPTransferClient).
- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    NSString *shortGUID = [target isKindOfClass:NSURL.class] ? VibeICloudLinkShortGUID(target) : nil;
    if (!shortGUID) {
        [super makeRequestForTarget:target state:state completion:completion];
        return;
    }
    NSDictionary *stale = state[kStateStaleLookup];
    [self lookUpShortGUID:shortGUID unlike:stale completion:^(NSDictionary *file, NSError *error) {
        if (!file) {
            completion(nil, error);
            return;
        }
        state[kStateLookup] = file;
        if (stale) {
            state[kStateStaleLookup] = nil;
            state[kStateRefreshedLookup] = file;
        }
        NSURL *address = VibeICloudLinkDownloadURL(file[@"address"], file[@"name"]);
        if (!address) {
            completion(nil, VibeLinkMakeError(VibeLinkErrorICloudUnreadable, nil));
            return;
        }
        [super makeRequestForTarget:address state:state completion:completion];
    }];
}

// An iCloud address refused may only have expired. It is looked up again
// once, then sent again. The fresh address's own refusal fails.
- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger))resend
                       fail:(void (^)(NSError *))fail {
    NSDictionary *lookup = state[kStateLookup];
    if (lookup && lookup != state[kStateRefreshedLookup] && VibeICloudLinkStatusIsStaleAddress(status)) {
        LogInfo(@"Links: an iCloud address was refused (HTTP %ld); looking it up again", (long)status);
        state[kStateStaleLookup] = lookup;
        resend(attempt);
        return;
    }
    [super handleFailureStatus:status data:data retryAfter:retryAfter state:state attempt:attempt
                        resend:resend fail:fail];
}

// The lookup states the file: its version, its mtime, and its name.
// TRAP: the version is the checksum, never a header. Last-Modified is when
// the address was signed, and there is no ETag. Read as a version, every
// lookup would be another one: a resend would fail and a kept download would
// be fetched again.
- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response
                               state:(NSMutableDictionary<NSString *, id> *)state {
    NSDictionary *metadata = [super metadataOfResponse:response state:state];
    NSDictionary *lookup = state[kStateLookup];
    if (!lookup) {
        return metadata;
    }
    NSMutableDictionary *file = [metadata mutableCopy];
    file[@"checksum"] = lookup[@"checksum"];
    file[@"modified"] = lookup[@"modified"];
    file[@"contentDisposition"] = VibeICloudLinkContentDisposition(lookup[@"name"]);
    [file removeObjectForKey:@"lastModified"];
    return file;
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    NSString *checksum = metadata[@"checksum"];
    return [checksum isKindOfClass:NSString.class] ? checksum : [super versionOfMetadata:metadata];
}

// An iCloud share's id is its key: anyone holding it reads the file.
- (NSString *)descriptionOfTarget:(id)target {
    if ([target isKindOfClass:NSURL.class] && VibeICloudLinkShortGUID(target)) {
        return [NSString stringWithFormat:@"%@/iclouddrive", [target host]];
    }
    return [super descriptionOfTarget:target];
}

@end

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
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    NSURL *directory = [self directoryOfLink:target];
    return [super readTarget:target offset:offset length:length
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
    // TRAP: a file being fetched now keeps its placeholder, from the fetch's
    // start, before its first response. The fetch's install renames the bytes
    // it downloaded over whatever stands at the URL, and its readers hold the
    // part file. A new name would leave that install a second file. Only the
    // record changes, and the install's mtime hook sets it back to what was
    // downloaded.
    if (existing && [self isFetchingURL:existing]) {
        LogInfo(@"Links: %@ changed while it is fetched; updating its record only", link.host);
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
