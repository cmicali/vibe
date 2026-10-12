//
//  LinkClient.m
//  Vibe
//

#import "LinkClient.h"

#include <os/lock.h>

#import "HTTPTransferClientInternal.h"
#import "ICloudLinkRules.h"
#import "LinkStore.h"

// A transfer's state: the lookup its attempt was sent with, and whether a
// refused address was looked up again. A transfer does that once.
static NSString *const kStateLookup = @"lookup";
static NSString *const kStateRefreshed = @"refreshed";
// A lookup that lost its connection is sent again this many times, this far
// apart, as a download's dropped connection is (HTTPTransferClient). A
// download waiting on it would otherwise fail on one blip.
static const NSInteger kLookupNetworkRetries = 2;
static const NSTimeInterval kLookupNetworkRetryDelay = 1;

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
    [self sendLookupOfShortGUID:shortGUID attempt:1 completion:^(NSDictionary *file, NSError *error) {
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

// A lost connection is sent again, twice at most. A throttle waits and is
// sent again, as a request's does (resendAfterStatus:). Past those, a
// network failure passes through as itself: a download keeps its part, and
// a probe fails as unreachable. A status fails as the server's. Any answer
// that is not one file shared with anyone fails with its link error.
- (void)sendLookupOfShortGUID:(NSString *)shortGUID
                      attempt:(NSInteger)attempt
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
    NSTimeInterval sent = NSProcessInfo.processInfo.systemUptime;
    void (^again)(NSInteger) = ^(NSInteger nextAttempt) {
        [self sendLookupOfShortGUID:shortGUID attempt:nextAttempt completion:completion];
    };
    [[self.callSession dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error && VibeHTTPIsConnectionError(error) && attempt <= kLookupNetworkRetries) {
            LogInfo(@"Links: the iCloud lookup failed (%@); sending it again", error.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kLookupNetworkRetryDelay * self.retryDelayScale * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                again(attempt + 1);
            });
            return;
        }
        if (error) {
            LogInfo(@"Links: the iCloud lookup failed: %@", error.localizedDescription);
            completion(nil, error);
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = http.statusCode;
        if (status != 200 && [self resendAfterStatus:status retryAfter:[http valueForHTTPHeaderField:@"Retry-After"]
                                             attempt:attempt resend:again]) {
            LogInfo(@"Links: the iCloud lookup answered HTTP %ld; sending it again", (long)status);
            return;
        }
        if (status != 200) {
            NSString *summary = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            LogWarn(@"Links: the iCloud lookup answered %@", summary);
            completion(nil, [NSError errorWithDomain:VibeHTTPErrorDomain code:VibeHTTPErrorStatus
                                            userInfo:@{NSLocalizedDescriptionKey: summary,
                                                       VibeHTTPErrorStatusCodeKey: @(status)}]);
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
