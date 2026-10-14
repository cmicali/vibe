//
//  LinkClient.m
//  Vibe
//

#import "LinkClient.h"

#include <os/lock.h>

#import "DropboxLinkRules.h"
#import "HTTPTransferClientInternal.h"
#import "ICloudLinkRules.h"
#import "LinkStore.h"

// A transfer's state: the lookup its attempt was sent with, and whether a
// refused address was looked up again. A transfer does that once.
static NSString *const kStateLookup = @"lookup";
static NSString *const kStateRefreshed = @"refreshed";
// A call that lost its connection is sent again this many times, this far
// apart, as a download's dropped connection is (HTTPTransferClient). A
// download waiting on a lookup would otherwise fail on one blip.
static const NSInteger kCallNetworkRetries = 2;
static const NSTimeInterval kCallNetworkRetryDelay = 1;

@implementation LinkClient {
    os_unfair_lock _lookupLock;
    // Each share's last lookup, by its short GUID, with `lookedUp`: the
    // system's uptime when it was sent. Under the lock.
    NSMutableDictionary<NSString *, NSDictionary *> *_lookups;
    // The lookup claim: each share's waiters while its lookup is in flight.
    // Under the lock.
    NSMutableDictionary<NSString *, NSMutableArray *> *_lookupWaiters;
    // Moved by each session swap. A lookup the old sessions answer names the
    // old server's address, so it is handed to its waiters but not kept.
    // Under the lock.
    uint64_t _lookupsGeneration;
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

// A lookup the old sessions answered names that server's addresses.
// TRAP: the base's init calls this before the ivars are set. The lock is
// then zero, which is its initial value, and the cache is nil.
- (void)useSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    [super useSessionConfiguration:configuration];
    os_unfair_lock_lock(&_lookupLock);
    [_lookups removeAllObjects];
    _lookupsGeneration++;
    os_unfair_lock_unlock(&_lookupLock);
}

// The share's file: the last lookup while it is fresh, else a new one.
// Single-flight: a caller arriving during a lookup waits on that one. Any
// thread.
- (void)lookUpShortGUID:(NSString *)shortGUID
             completion:(void (^)(NSDictionary *_Nullable file, NSError *_Nullable error))completion {
    os_unfair_lock_lock(&_lookupLock);
    NSDictionary *last = _lookups[shortGUID];
    if (last && VibeICloudLinkAddressIsFresh([last[@"lookedUp"] doubleValue], NSProcessInfo.processInfo.systemUptime)) {
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
    uint64_t generation = _lookupsGeneration;
    os_unfair_lock_unlock(&_lookupLock);
    if (!owner) {
        return;
    }
    [self sendLookupOfShortGUID:shortGUID completion:^(NSDictionary *file, NSError *error) {
        os_unfair_lock_lock(&self->_lookupLock);
        NSArray *settled = self->_lookupWaiters[shortGUID];
        [self->_lookupWaiters removeObjectForKey:shortGUID];
        if (file && generation == self->_lookupsGeneration) {
            self->_lookups[shortGUID] = file;
        }
        os_unfair_lock_unlock(&self->_lookupLock);
        for (void (^waiter)(NSDictionary *, NSError *) in settled) {
            waiter(file, error);
        }
    }];
}

// One call on the call session, answered whole: the iCloud lookup and a
// Dropbox folder's listing. allowsURL is asked first. A lost connection is
// sent again, twice at most. A throttle waits and is sent again, as a
// request is (resendAfterStatus:). Past those, a network failure passes
// through as itself: a download keeps its part, and a probe fails as
// unreachable. Any status but 200 fails as the server's. `what` names the
// call in the log. A call cancelled before a send completes with
// VibeHTTPErrorCancelled.
- (void)sendCall:(NSURLRequest *)request
            what:(NSString *)what
         attempt:(NSInteger)attempt
       cancelled:(nullable BOOL (^)(void))cancelled
      completion:(void (^)(NSData *_Nullable data, NSHTTPURLResponse *_Nullable response,
                           NSError *_Nullable error))completion {
    if (cancelled && cancelled()) {
        completion(nil, nil, [self errorWithCode:VibeHTTPErrorCancelled description:@"cancelled"]);
        return;
    }
    BOOL (^allows)(NSURL *, NSURL *) = self.allowsURL;
    if (allows && !allows(nil, request.URL)) {
        completion(nil, nil, [self errorWithCode:VibeHTTPErrorRefusedURL description:@"the address is not allowed"]);
        return;
    }
    void (^again)(NSInteger) = ^(NSInteger nextAttempt) {
        [self sendCall:request what:what attempt:nextAttempt cancelled:cancelled completion:completion];
    };
    [[self.callSession dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error && VibeHTTPIsConnectionError(error) && attempt <= kCallNetworkRetries) {
            LogInfo(@"Links: %@ failed (%@); sending it again", what, error.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kCallNetworkRetryDelay * self.retryDelayScale * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                again(attempt + 1);
            });
            return;
        }
        if (error) {
            LogInfo(@"Links: %@ failed: %@", what, error.localizedDescription);
            completion(nil, nil, error);
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = http.statusCode;
        if (status != 200 && [self resendAfterStatus:status retryAfter:[http valueForHTTPHeaderField:@"Retry-After"]
                                             attempt:attempt resend:again]) {
            LogInfo(@"Links: %@ answered HTTP %ld; sending it again", what, (long)status);
            return;
        }
        if (status != 200) {
            NSString *summary = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            LogWarn(@"Links: %@ answered %@", what, summary);
            completion(nil, http, [NSError errorWithDomain:VibeHTTPErrorDomain code:VibeHTTPErrorStatus
                                                  userInfo:@{NSLocalizedDescriptionKey: summary,
                                                             VibeHTTPErrorStatusCodeKey: @(status)}]);
            return;
        }
        completion(data, http, nil);
    }] resume];
}

// Any answer that is not one file shared with anyone fails with its link
// error. The call's failures are sendCall:'s.
- (void)sendLookupOfShortGUID:(NSString *)shortGUID
                   completion:(void (^)(NSDictionary *_Nullable file, NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kVibeICloudLinkLookupURL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.icloud.com" forHTTPHeaderField:@"Origin"];
    request.HTTPBody = VibeICloudLinkLookupBody(shortGUID);
    NSTimeInterval sent = NSProcessInfo.processInfo.systemUptime;
    [self sendCall:request what:@"the iCloud lookup" attempt:1 cancelled:nil
        completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
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
        LogInfo(@"Links: looked up an iCloud file of %@ bytes", file[@"size"]);
        completion(looked, nil);
    }];
}

#pragma mark - Dropbox folders

- (dispatch_block_t)listDropboxFolder:(NSDictionary<NSString *, NSString *> *)token
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(NSString *, NSArray<NSDictionary *> *, NSError *))completion {
    NSMutableDictionary *flow = [NSMutableDictionary dictionary];
    BOOL (^cancelled)(void) = ^BOOL {
        @synchronized (flow) {
            return flow[@"stopped"] != nil;
        }
    };
    dispatch_block_t cancel = ^{
        @synchronized (flow) {
            flow[@"stopped"] = @YES;
        }
    };
    NSURL *pageURL = VibeDropboxFolderLinkURL(token);
    if (!pageURL) {
        completion(nil, nil, VibeLinkMakeError(VibeLinkErrorInvalid, nil));
        return cancel;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:pageURL];
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = timeout;
    [self sendCall:request what:@"the Dropbox folder page" attempt:1 cancelled:cancelled
        completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        NSArray<NSHTTPCookie *> *cookies =
                [NSHTTPCookie cookiesWithResponseHeaderFields:(NSDictionary<NSString *, NSString *> *)response.allHeaderFields
                                                       forURL:response.URL ?: pageURL];
        NSString *t = nil;
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.name isEqualToString:@"t"]) {
                t = cookie.value;
            }
        }
        if (t.length == 0) {
            LogWarn(@"Links: the Dropbox folder page set no t cookie");
            completion(nil, nil, VibeLinkMakeError(VibeLinkErrorNotAudio, nil));
            return;
        }
        NSDictionary *call = @{@"cookie": [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"] ?: @"",
                               @"t": t, @"timeout": @(timeout)};
        [self filesOfDropboxFolder:token call:call visited:[NSMutableSet set] cancelled:cancelled
                        completion:^(NSString *name, NSArray<NSDictionary *> *files, NSError *listError) {
            if (files) {
                LogInfo(@"Links: listed a Dropbox folder of %lu files", (unsigned long)files.count);
            }
            completion(name, files, listError);
        }];
    }];
    return cancel;
}

// One folder's files: its pages in order, then each entry in turn, with a
// folder's own files in its place. call is {cookie, t, timeout}. A folder
// listed once already lists nothing, so a listing that names a folder above
// it cannot loop.
- (void)filesOfDropboxFolder:(NSDictionary<NSString *, NSString *> *)token
                        call:(NSDictionary *)call
                     visited:(NSMutableSet<NSString *> *)visited
                   cancelled:(BOOL (^)(void))cancelled
                  completion:(void (^)(NSString *_Nullable name, NSArray<NSDictionary *> *_Nullable files,
                                       NSError *_Nullable error))completion {
    @synchronized (visited) {
        if ([visited containsObject:token[@"subPath"]]) {
            completion(nil, @[], nil);
            return;
        }
        [visited addObject:token[@"subPath"]];
    }
    [self pageOfDropboxFolder:token voucher:nil entries:[NSMutableArray array] call:call cancelled:cancelled
                   completion:^(NSString *name, NSArray<NSDictionary *> *entries, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        [self appendFilesOfEntries:entries from:0 into:files call:call visited:visited cancelled:cancelled
                        completion:^(NSError *entriesError) {
            completion(name, entriesError ? nil : files, entriesError);
        }];
    }];
}

// The folder's entries from the page `voucher` names, nil for the first, to
// its last page. name is the first page that states one.
- (void)pageOfDropboxFolder:(NSDictionary<NSString *, NSString *> *)token
                    voucher:(nullable NSString *)voucher
                    entries:(NSMutableArray<NSDictionary *> *)entries
                       call:(NSDictionary *)call
                  cancelled:(BOOL (^)(void))cancelled
                 completion:(void (^)(NSString *_Nullable name, NSArray<NSDictionary *> *_Nullable entries,
                                      NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kVibeDropboxFolderListingURL]];
    request.HTTPMethod = @"POST";
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = [call[@"timeout"] doubleValue];
    request.HTTPBody = VibeDropboxFolderListingBody(token, call[@"t"], voucher);
    [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [request setValue:@"https://www.dropbox.com" forHTTPHeaderField:@"Origin"];
    [request setValue:call[@"cookie"] forHTTPHeaderField:@"Cookie"];
    [self sendCall:request what:@"the Dropbox folder listing" attempt:1 cancelled:cancelled
        completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        id answer = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *next = nil;
        NSString *name = nil;
        NSArray<NSDictionary *> *page = VibeDropboxFolderListingEntries(answer, token, &next, &name);
        if (!page) {
            LogWarn(@"Links: the Dropbox folder listing answered no entries");
            completion(nil, nil, VibeLinkMakeError(VibeLinkErrorNotAudio, nil));
            return;
        }
        [entries addObjectsFromArray:page];
        // A voucher that names its own page again ends the listing.
        if (next && ![next isEqualToString:voucher]) {
            [self pageOfDropboxFolder:token voucher:next entries:entries call:call cancelled:cancelled
                           completion:^(NSString *laterName, NSArray<NSDictionary *> *all, NSError *laterError) {
                completion(name ?: laterName, all, laterError);
            }];
            return;
        }
        completion(name, entries, nil);
    }];
}

// The files from entries[index] on, appended in order. A folder's files are
// listed when it is reached.
- (void)appendFilesOfEntries:(NSArray<NSDictionary *> *)entries
                        from:(NSUInteger)index
                        into:(NSMutableArray<NSDictionary *> *)files
                        call:(NSDictionary *)call
                     visited:(NSMutableSet<NSString *> *)visited
                   cancelled:(BOOL (^)(void))cancelled
                  completion:(void (^)(NSError *_Nullable error))completion {
    while (index < entries.count && ![entries[index][@"folder"] boolValue]) {
        [files addObject:entries[index++]];
    }
    if (index == entries.count) {
        completion(nil);
        return;
    }
    [self filesOfDropboxFolder:entries[index][@"token"] call:call visited:visited cancelled:cancelled
                    completion:^(NSString *name, NSArray<NSDictionary *> *folderFiles, NSError *error) {
        if (error) {
            completion(error);
            return;
        }
        [files addObjectsFromArray:folderFiles];
        [self appendFilesOfEntries:entries from:index + 1 into:files call:call visited:visited cancelled:cancelled
                        completion:completion];
    }];
}

#pragma mark - Requests

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
    [self lookUpShortGUID:shortGUID completion:^(NSDictionary *file, NSError *error) {
        if (!file) {
            completion(nil, error);
            return;
        }
        state[kStateLookup] = file;
        [super makeRequestForTarget:file[@"url"] state:state completion:completion];
    }];
}

// An iCloud address refused may only have expired. Its lookup is forgotten,
// unless another request already replaced it, and the request is sent again
// on a fresh one. A transfer does that once. A second refusal fails.
- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger))resend
                       fail:(void (^)(NSError *))fail {
    NSDictionary *lookup = state[kStateLookup];
    if (lookup && ![state[kStateRefreshed] boolValue] && VibeICloudLinkStatusIsStaleAddress(status)) {
        LogInfo(@"Links: an iCloud address was refused (HTTP %ld); looking it up again", (long)status);
        os_unfair_lock_lock(&_lookupLock);
        [_lookups removeObjectsForKeys:[_lookups allKeysForObject:lookup]];
        os_unfair_lock_unlock(&_lookupLock);
        state[kStateRefreshed] = @YES;
        resend(attempt);
        return;
    }
    [super handleFailureStatus:status data:data retryAfter:retryAfter state:state attempt:attempt
                        resend:resend fail:fail];
}

// The lookup states the file: its version, its mtime, and its name.
// TRAP: the version is the checksum, never a header. It stands as a strong
// ETag, which the base takes as the version. Last-Modified is when the
// address was signed, and there is no ETag. Read as a version, every lookup
// would be another one: a resend would fail and a kept download would be
// fetched again.
- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response
                               state:(NSMutableDictionary<NSString *, id> *)state {
    NSDictionary *metadata = [super metadataOfResponse:response state:state];
    NSDictionary *lookup = state[kStateLookup];
    if (!lookup) {
        return metadata;
    }
    NSMutableDictionary *file = [metadata mutableCopy];
    file[@"etag"] = [NSString stringWithFormat:@"\"%@\"", lookup[@"checksum"]];
    file[@"modified"] = lookup[@"modified"];
    file[@"contentDisposition"] = VibeICloudLinkContentDisposition(lookup[@"name"]);
    [file removeObjectForKey:@"lastModified"];
    return file;
}

// An iCloud share's id is its key: anyone holding it reads the file.
- (NSString *)descriptionOfTarget:(id)target {
    if ([target isKindOfClass:NSURL.class] && VibeICloudLinkShortGUID(target)) {
        return [NSString stringWithFormat:@"%@/iclouddrive", [target host]];
    }
    return [super descriptionOfTarget:target];
}

@end
