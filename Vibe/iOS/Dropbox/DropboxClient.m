//
//  DropboxClient.m
//  Vibe (iOS)
//

#import "DropboxClientInternal.h"

#import <Security/Security.h>
#include <os/lock.h>

#import "DropboxRules.h"

NSErrorDomain const VibeDropboxErrorDomain = @"com.commonwealthrecordings.Vibe.Dropbox";
NSNotificationName const VibeDropboxAccountDidChangeNotification =
        @"VibeDropboxAccountDidChangeNotification";

// A throttled or briefly unavailable call is tried this many times in all.
static const NSInteger kMaximumAttempts = 4;
// A download whose connection dropped after its file was made resumes this
// many times in a row with no byte arriving between: one outlasts a handoff
// between networks, a second a flap, and past that the link is down and the
// open should fail rather than hold its materialization lane. A byte that
// arrives resets the count, so a long download over a poor link finishes.
static const NSInteger kMaximumNetworkRetries = 2;
static const NSTimeInterval kNetworkRetryDelay = 1;
// An access token this close to its expiry is refreshed instead of used.
static const NSTimeInterval kAccessTokenMargin = 60;
// A Keychain still locked is asked again no sooner than this.
static const NSTimeInterval kAccountLoadRetryInterval = 5;

static NSDictionary *_Nullable VibeJSONObject(NSData *_Nullable data) {
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSData *VibeRandomBytes(size_t count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    if (SecRandomCopyBytes(kSecRandomDefault, count, data.mutableBytes) != errSecSuccess) {
        arc4random_buf(data.mutableBytes, count);
    }
    return data;
}

static NSError *VibeCancelledError(void) {
    return VibeDropboxMakeError(VibeDropboxErrorCancelled, @"cancelled");
}

// The metadata a content response carries in its Dropbox-API-Result header.
static NSDictionary *_Nullable VibeDropboxAPIResult(NSHTTPURLResponse *http) {
    return VibeJSONObject([[http valueForHTTPHeaderField:@"Dropbox-API-Result"] dataUsingEncoding:NSUTF8StringEncoding]);
}

typedef void (^VibeDropboxTokenWaiter)(NSString *_Nullable token, uint64_t accountGeneration,
                                       NSError *_Nullable error);

#pragma mark - Transfer state

// A download or a ranged read in flight. The cancel flag, the task and
// bytesWritten are under the client's lock; the rest belongs to whichever
// step runs, and attempts never overlap.
@interface DropboxTransfer : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSInteger attempts;
@property (nonatomic) BOOL refreshed;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finished;
@property (nonatomic, nullable) NSURLSessionDataTask *task;
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic) uint64_t accountGeneration;
// The download's metadata, or the read's bytes; finishTransfer: calls it once.
@property (nonatomic, copy, nullable) void (^completion)(id _Nullable, NSError *_Nullable);
// A ranged read's metadata is its answer's. A download's only: the file,
// made at the first accepted response, and that response's metadata and size
// span every attempt; bytesWritten is the resume offset. The rest is per
// response.
@property (nonatomic, copy, nullable) NSURL *destination;
@property (nonatomic, copy, nullable) void (^progress)(uint64_t, int64_t, NSString *_Nullable);
@property (nonatomic, nullable) NSFileHandle *file;
@property (nonatomic, nullable) NSDictionary *metadata;
@property (nonatomic) int64_t size;
@property (nonatomic) uint64_t bytesWritten;
@property (nonatomic) NSInteger networkRetries;
@property (nonatomic) NSInteger status;
// A whole-file answer to a ranged resend: the bytes already written, skipped.
@property (nonatomic) uint64_t skip;
@property (nonatomic, nullable) NSMutableData *errorData;
@property (nonatomic, copy, nullable) NSString *retryAfter;
// The transfer's own reason to stop: a disk write, or a changed version.
@property (nonatomic, nullable) NSError *failure;
@end

@implementation DropboxTransfer
@end

#pragma mark - Client

@interface DropboxClient () <NSURLSessionDataDelegate,
                             ASWebAuthenticationPresentationContextProviding>
@end

@implementation DropboxClient {
    NSString *_appKey;
    NSString *_keychainService;
    NSURLSessionConfiguration *_configuration;
    // Streamed downloads, through the delegate below.
    NSURLSession *_downloadSession;
    // Everything answered whole — calls, tokens, ranged reads — on its own
    // queue, so a tag read never waits behind a download's disk writes.
    NSURLSession *_callSession;

    os_unfair_lock _lock;
    NSString *_refreshToken;
    NSString *_accountIDValue;
    NSString *_accountNameValue;
    NSString *_accessToken;
    CFAbsoluteTime _accessTokenExpiry;
    // The refresh claim: nil when none is in flight, else its waiters.
    NSMutableArray<VibeDropboxTokenWaiter> *_refreshWaiters;
    // Bumped by every sign-in and sign-out, so a refresh or a 401 that
    // belongs to the previous account can neither restore nor unlink it.
    uint64_t _accountGeneration;
    // The Keychain answered "locked" (a launch before first unlock): the
    // account is read again at the next use rather than taken as absent, at
    // most once per kAccountLoadRetryInterval, since every accessor asks.
    BOOL _accountLoadDeferred;
    CFAbsoluteTime _accountLoadRetryAt;
    NSMutableDictionary<NSNumber *, DropboxTransfer *> *_downloads;
    BOOL _warmedUp;

    // Main thread: the sign-in in progress.
    ASWebAuthenticationSession *_webSession;
    ASPresentationAnchor _anchor;
}

- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _appKey = [appKey copy];
        _keychainService = [keychainService copy];
        _configuration = configuration;
        _lock = OS_UNFAIR_LOCK_INIT;
        _downloads = [NSMutableDictionary dictionary];
        [self useSessionConfiguration:nil];
        [self loadAccount];
    }
    return self;
}

- (void)useSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    configuration = configuration ?: _configuration;
    [_downloadSession finishTasksAndInvalidate];
    [_callSession finishTasksAndInvalidate];
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    delegateQueue.name = @"com.commonwealthrecordings.Vibe.dropbox";
    // TRAP: a delegate session retains its delegate until invalidated. The
    // client lives as long as the app, so only a replaced session is.
    _downloadSession = [NSURLSession sessionWithConfiguration:configuration
                                                     delegate:self
                                                delegateQueue:delegateQueue];
    _callSession = [NSURLSession sessionWithConfiguration:configuration];
}

#pragma mark - Account

- (BOOL)isLinked {
    [self retryDeferredAccountLoad];
    os_unfair_lock_lock(&_lock);
    BOOL linked = _refreshToken != nil;
    os_unfair_lock_unlock(&_lock);
    return linked;
}

- (NSString *)accountID {
    [self retryDeferredAccountLoad];
    os_unfair_lock_lock(&_lock);
    NSString *value = _accountIDValue;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (NSString *)accountName {
    os_unfair_lock_lock(&_lock);
    NSString *value = _accountNameValue;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)retryDeferredAccountLoad {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_lock);
    BOOL due = _accountLoadDeferred && now >= _accountLoadRetryAt;
    if (due) {
        _accountLoadRetryAt = now + kAccountLoadRetryInterval;
    }
    os_unfair_lock_unlock(&_lock);
    if (due) {
        [self loadAccount];
    }
}

// The one writer of the account: a sign-in, an adopt, a sign-out (all nil)
// and an unlink. Under the lock; moves the generation.
- (void)replaceAccountLockedWithRefreshToken:(NSString *)refresh
                                 accessToken:(NSString *)access
                                   expiresIn:(NSTimeInterval)expiresIn
                                   accountID:(NSString *)accountID {
    _accountGeneration++;
    _refreshToken = [refresh copy];
    _accessToken = [access copy];
    _accessTokenExpiry = access ? CFAbsoluteTimeGetCurrent() + expiresIn : 0;
    _accountIDValue = [accountID isKindOfClass:NSString.class] ? [accountID copy] : nil;
    _accountNameValue = nil;
}

- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: _keychainService,
        (__bridge id)kSecAttrAccount: @"account",
    };
}

// TRAP: before the device's first unlock the item reads as locked, not
// absent; taken as absent, the whole session would run signed out.
- (void)loadAccount {
    if (!_keychainService) {
        return;
    }
    NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSDictionary *account = status == errSecSuccess ? VibeJSONObject((__bridge_transfer NSData *)result) : nil;
    NSString *refresh = account[@"refresh_token"];
    BOOL found = [refresh isKindOfClass:NSString.class] && refresh.length > 0;
    os_unfair_lock_lock(&_lock);
    BOOL wasDeferred = _accountLoadDeferred;
    BOOL stillDeferred = status == errSecInteractionNotAllowed;
    _accountLoadDeferred = stillDeferred;
    // A sign-in made meanwhile is newer than what the Keychain held.
    BOOL adopt = found && !_refreshToken;
    if (adopt) {
        [self replaceAccountLockedWithRefreshToken:refresh accessToken:nil expiresIn:0
                                         accountID:account[@"account_id"]];
        _accountNameValue = [account[@"name"] isKindOfClass:NSString.class] ? account[@"name"] : nil;
    }
    os_unfair_lock_unlock(&_lock);
    if (status != errSecSuccess && status != errSecItemNotFound && !(wasDeferred && stillDeferred)) {
        LogWarn(@"Dropbox: keychain read failed: %d", (int)status);
    }
    // At launch nothing is listening yet; a deferred read lands mid-session.
    if (adopt && wasDeferred) {
        LogInfo(@"Dropbox: account read once the device unlocked");
        [self postAccountDidChange];
    }
}

// Called with the lock NOT held; snapshot what to persist first.
- (void)saveRefreshToken:(NSString *)refresh accountID:(NSString *)accountID name:(NSString *)name {
    if (!_keychainService) {
        return;
    }
    NSMutableDictionary *account = [NSMutableDictionary dictionary];
    account[@"refresh_token"] = refresh;
    account[@"account_id"] = accountID;
    account[@"name"] = name;
    NSData *data = [NSJSONSerialization dataWithJSONObject:account options:0 error:NULL];
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    NSMutableDictionary *item = [[self keychainQuery] mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    // After first unlock: a refresh must work under the lock screen while
    // background playback downloads the next track. This device only: a
    // restored backup on another phone signs in again.
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) {
        LogError(@"Dropbox: keychain write failed: %d", (int)status);
    }
}

- (void)deleteSavedAccount {
    if (_keychainService) {
        SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    }
}

- (void)postAccountDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VibeDropboxAccountDidChangeNotification
                                                          object:self];
    });
}

// The grant is gone (revoked on dropbox.com, or the refresh refused): forget
// it, unless a newer sign-in or sign-out already moved past it.
- (void)unlinkAccountGeneration:(uint64_t)generation reason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    BOOL current = generation == _accountGeneration && _refreshToken != nil;
    if (current) {
        [self replaceAccountLockedWithRefreshToken:nil accessToken:nil expiresIn:0 accountID:nil];
    }
    os_unfair_lock_unlock(&_lock);
    if (!current) {
        return;
    }
    LogWarn(@"Dropbox: account unlinked: %@", reason);
    [self deleteSavedAccount];
    [self postAccountDidChange];
}

- (void)adoptRefreshToken:(NSString *)refreshToken accountID:(NSString *)accountID {
    os_unfair_lock_lock(&_lock);
    [self replaceAccountLockedWithRefreshToken:refreshToken accessToken:nil expiresIn:0 accountID:accountID];
    os_unfair_lock_unlock(&_lock);
    [self saveRefreshToken:refreshToken accountID:accountID name:nil];
    [self postAccountDidChange];
}

#pragma mark - Sign-in

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return _anchor;
}

- (void)signInWithPresentationAnchor:(ASPresentationAnchor)anchor
                          completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"main thread");
    [_webSession cancel];
    NSString *verifier = VibeDropboxBase64URL(VibeRandomBytes(32));
    NSString *state = VibeDropboxBase64URL(VibeRandomBytes(16));
    NSURL *url = VibeDropboxAuthorizeURL(_appKey, VibeDropboxCodeChallenge(verifier), state);

    __weak DropboxClient *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DropboxClient *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_webSession = nil;
                strongSelf->_anchor = nil;
            }
            completion(error);
        });
    };
    ASWebAuthenticationSession *session = [[ASWebAuthenticationSession alloc]
            initWithURL:url
      callbackURLScheme:VibeDropboxCallbackScheme(_appKey)
      completionHandler:^(NSURL *callbackURL, NSError *error) {
        DropboxClient *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (!callbackURL) {
            // Closing the sheet is the user's answer, not a failure to report.
            BOOL cancelled = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]
                    && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
            finish(cancelled ? nil : VibeDropboxMakeError(VibeDropboxErrorSignInFailed,
                                                          error.localizedDescription ?: @"sign-in failed"));
            return;
        }
        NSString *reason = nil;
        NSString *code = VibeDropboxAuthorizationCode(callbackURL, state, &reason);
        if (!code) {
            finish(VibeDropboxMakeError(VibeDropboxErrorSignInFailed, reason));
            return;
        }
        [strongSelf exchangeCode:code verifier:verifier completion:finish];
    }];
    session.presentationContextProvider = self;
    _anchor = anchor;
    _webSession = session;
    if (![session start]) {
        finish(VibeDropboxMakeError(VibeDropboxErrorSignInFailed, @"could not present sign-in"));
    }
}

- (void)exchangeCode:(NSString *)code
            verifier:(NSString *)verifier
          completion:(void (^)(NSError *))completion {
    NSDictionary *fields = @{
        @"code": code,
        @"grant_type": @"authorization_code",
        @"code_verifier": verifier,
        @"client_id": _appKey,
        @"redirect_uri": VibeDropboxRedirectURI(_appKey),
    };
    [self postTokenForm:fields completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *refresh = body[@"refresh_token"];
        NSString *access = body[@"access_token"];
        if (error || ![refresh isKindOfClass:NSString.class] || ![access isKindOfClass:NSString.class]) {
            completion(error ?: VibeDropboxMakeError(VibeDropboxErrorSignInFailed,
                                                     VibeDropboxErrorSummary(status, body)));
            return;
        }
        os_unfair_lock_lock(&self->_lock);
        [self replaceAccountLockedWithRefreshToken:refresh accessToken:access
                                         expiresIn:[body[@"expires_in"] doubleValue]
                                         accountID:body[@"account_id"]];
        os_unfair_lock_unlock(&self->_lock);
        [self saveRefreshToken:refresh accountID:self.accountID name:nil];
        [self postAccountDidChange];
        // What the grant carries; a scope missing here is the App Console's
        // Permissions tab, and every call that needs it answers 400.
        LogInfo(@"Dropbox: signed in, scopes: %@", body[@"scope"] ?: @"(none listed)");
        [self refreshAccountNameWithCompletion:^{
            completion(nil);
        }];
    }];
}

// The display name for Settings. A failure leaves it nil and the account
// linked: the name is decoration.
- (void)refreshAccountNameWithCompletion:(dispatch_block_t)completion {
    os_unfair_lock_lock(&_lock);
    uint64_t generation = _accountGeneration;
    os_unfair_lock_unlock(&_lock);
    [self callEndpoint:@"users/get_current_account" arguments:nil
            completion:^(NSDictionary *result, NSError *error) {
        NSDictionary *name = result[@"name"];
        NSString *display = [name isKindOfClass:NSDictionary.class] ? name[@"display_name"] : nil;
        NSString *accountID = result[@"account_id"];
        if ([display isKindOfClass:NSString.class]) {
            os_unfair_lock_lock(&self->_lock);
            // Only the account it was asked for: an answer that outlived a
            // sign-out and the next sign-in would stamp that account with
            // this one's name and ID, and the mirror's directory is the ID.
            NSString *refresh = generation == self->_accountGeneration ? self->_refreshToken : nil;
            if (refresh) {
                self->_accountNameValue = display;
                if ([accountID isKindOfClass:NSString.class]) {
                    self->_accountIDValue = accountID;
                }
            }
            NSString *savedID = self->_accountIDValue;
            os_unfair_lock_unlock(&self->_lock);
            if (refresh) {
                [self saveRefreshToken:refresh accountID:savedID name:display];
                [self postAccountDidChange];
            }
        }
        completion();
    }];
}

- (void)signOut {
    os_unfair_lock_lock(&_lock);
    NSString *refresh = _refreshToken;
    // An expired one is refused and the grant would outlive the sign-out.
    NSString *access = _accessTokenExpiry - kAccessTokenMargin > CFAbsoluteTimeGetCurrent() ? _accessToken : nil;
    [self replaceAccountLockedWithRefreshToken:nil accessToken:nil expiresIn:0 accountID:nil];
    os_unfair_lock_unlock(&_lock);
    if (!refresh) {
        return;
    }
    [self deleteSavedAccount];
    [self postAccountDidChange];
    LogInfo(@"Dropbox: signed out");
    // Revoking needs a live access token; a stale one is refreshed first so
    // the grant really ends on Dropbox's side, not only here.
    void (^revoke)(NSString *) = ^(NSString *token) {
        NSURL *url = [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:@"auth/token/revoke"]];
        [[self->_callSession dataTaskWithRequest:[self requestForURL:url token:token]] resume];
    };
    if (access) {
        revoke(access);
        return;
    }
    [self postTokenForm:[self refreshFormForToken:refresh]
             completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *token = body[@"access_token"];
        if ([token isKindOfClass:NSString.class]) {
            revoke(token);
        }
    }];
}

#pragma mark - Requests

- (NSMutableURLRequest *)requestForURL:(NSURL *)url token:(NSString *)token {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (NSMutableURLRequest *)downloadRequestForPath:(NSString *)path token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:[VIBE_DROPBOX_CONTENT_BASE stringByAppendingString:@"files/download"]];
    NSMutableURLRequest *request = [self requestForURL:url token:token];
    [request setValue:VibeDropboxAPIArgHeader(@{@"path": path}) forHTTPHeaderField:@"Dropbox-API-Arg"];
    return request;
}

// One ladder for every call Dropbox refused: an expired access token
// refreshes once and resends, any other 401 unlinks, a throttle waits and
// resends, and the rest fail with Dropbox's own words. Exactly one of resend
// and fail runs.
- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      token:(NSString *)token
                 generation:(uint64_t)generation
                  refreshed:(BOOL)refreshed
                    attempt:(NSInteger)attempt
                     resend:(void (^)(BOOL refreshed, NSInteger attempt))resend
                       fail:(void (^)(NSError *error))fail {
    NSDictionary *body = VibeJSONObject(data);
    if (VibeDropboxIsExpiredAccessToken(status, body) && !refreshed) {
        [self discardAccessToken:token];
        resend(YES, attempt);
        return;
    }
    NSString *summary = VibeDropboxErrorSummary(status, body);
    // A 400 is Dropbox refusing the call's shape, and it says why in plain
    // text, not JSON.
    if (!body && data.length > 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        summary = [NSString stringWithFormat:@"%@: %@", summary,
                   text.length > 300 ? [text substringToIndex:300] : text];
    }
    if (status == 401) {
        [self unlinkAccountGeneration:generation reason:summary];
        fail(VibeDropboxMakeError(VibeDropboxErrorNotLinked, summary));
        return;
    }
    NSTimeInterval delay = VibeDropboxRetryDelay(status, retryAfter);
    if (delay >= 0 && attempt < kMaximumAttempts) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            resend(refreshed, attempt + 1);
        });
        return;
    }
    LogWarn(@"Dropbox: call failed: %@", summary);
    fail(VibeDropboxMakeError(VibeDropboxErrorAPI, summary));
}

#pragma mark - Access token

- (NSDictionary<NSString *, NSString *> *)refreshFormForToken:(NSString *)refresh {
    return @{@"grant_type": @"refresh_token", @"refresh_token": refresh, @"client_id": _appKey};
}

- (void)postTokenForm:(NSDictionary<NSString *, NSString *> *)fields
           completion:(void (^)(NSDictionary *_Nullable body, NSInteger status, NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:VIBE_DROPBOX_TOKEN_URL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = VibeDropboxFormBody(fields);
    [[_callSession dataTaskWithRequest:request
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        completion(VibeJSONObject(data), status, error);
    }] resume];
}

// Single-flight: every caller arriving during a refresh waits on that one.
- (void)withAccessToken:(VibeDropboxTokenWaiter)waiter {
    [self retryDeferredAccountLoad];
    os_unfair_lock_lock(&_lock);
    if (!_refreshToken) {
        os_unfair_lock_unlock(&_lock);
        waiter(nil, 0, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"no Dropbox account"));
        return;
    }
    if (_accessToken && _accessTokenExpiry - kAccessTokenMargin > CFAbsoluteTimeGetCurrent()) {
        NSString *token = _accessToken;
        uint64_t generation = _accountGeneration;
        os_unfair_lock_unlock(&_lock);
        waiter(token, generation, nil);
        return;
    }
    BOOL owner = _refreshWaiters == nil;
    if (owner) {
        _refreshWaiters = [NSMutableArray array];
    }
    [_refreshWaiters addObject:[waiter copy]];
    NSString *refresh = _refreshToken;
    uint64_t generation = _accountGeneration;
    os_unfair_lock_unlock(&_lock);
    if (!owner) {
        return;
    }
    [self postTokenForm:[self refreshFormForToken:refresh]
             completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *token = body[@"access_token"];
        BOOL granted = !error && [token isKindOfClass:NSString.class];
        os_unfair_lock_lock(&self->_lock);
        NSArray<VibeDropboxTokenWaiter> *waiters = self->_refreshWaiters;
        self->_refreshWaiters = nil;
        BOOL current = generation == self->_accountGeneration;
        if (granted && current) {
            self->_accessToken = token;
            self->_accessTokenExpiry = CFAbsoluteTimeGetCurrent() + [body[@"expires_in"] doubleValue];
        }
        os_unfair_lock_unlock(&self->_lock);

        NSError *failure = nil;
        if (!current) {
            failure = VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"account changed during refresh");
        }
        else if (!granted) {
            // 400 invalid_grant: the refresh token itself was revoked.
            if (!error && status == 400) {
                [self unlinkAccountGeneration:generation reason:VibeDropboxErrorSummary(status, body)];
                failure = VibeDropboxMakeError(VibeDropboxErrorNotLinked, VibeDropboxErrorSummary(status, body));
            }
            else {
                failure = error ?: VibeDropboxMakeError(VibeDropboxErrorAPI, VibeDropboxErrorSummary(status, body));
            }
        }
        for (VibeDropboxTokenWaiter each in waiters) {
            each(failure ? nil : token, generation, failure);
        }
    }];
}

- (void)discardAccessToken:(NSString *)token {
    os_unfair_lock_lock(&_lock);
    if ([_accessToken isEqualToString:token]) {
        _accessToken = nil;
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - RPC

- (void)callEndpoint:(NSString *)endpoint
           arguments:(NSDictionary *)arguments
          completion:(void (^)(NSDictionary *, NSError *))completion {
    [self callEndpoint:endpoint arguments:arguments attempt:1 refreshed:NO completion:completion];
}

- (void)callEndpoint:(NSString *)endpoint
           arguments:(NSDictionary *)arguments
             attempt:(NSInteger)attempt
           refreshed:(BOOL)refreshed
          completion:(void (^)(NSDictionary *, NSError *))completion {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }
        NSMutableURLRequest *request = [self requestForURL:
                [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:endpoint]] token:token];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        // An endpoint without arguments takes the JSON null, not an empty body.
        request.HTTPBody = arguments
                ? [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL]
                : [@"null" dataUsingEncoding:NSUTF8StringEncoding];
        [[self->_callSession dataTaskWithRequest:request
                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 200) {
                completion(VibeJSONObject(data) ?: @{}, nil);
                return;
            }
            [self handleFailureStatus:http.statusCode data:data
                           retryAfter:[http valueForHTTPHeaderField:@"Retry-After"]
                                token:token generation:generation refreshed:refreshed attempt:attempt
                               resend:^(BOOL nowRefreshed, NSInteger nextAttempt) {
                [self callEndpoint:endpoint arguments:arguments attempt:nextAttempt
                         refreshed:nowRefreshed completion:completion];
            } fail:^(NSError *failure) {
                completion(nil, failure);
            }];
        }] resume];
    }];
}

#pragma mark - Warm-up

- (void)warmUp {
    // Unlinked before first unlock too: the Keychain reads as no account.
    if (!self.isLinked) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    BOOL first = !_warmedUp;
    _warmedUp = YES;
    os_unfair_lock_unlock(&_lock);
    if (!first) {
        return;
    }
    // The access token lives in memory, so a launch's first request refreshes
    // it; this takes that round trip and its TLS handshake off the first play.
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *error) {
        if (!token) {
            return;
        }
        // A download naming no file: refused at once, and what it buys is the
        // connection to the content host, one per session, since a session's
        // connections are its own (the download on one, its tail on the other).
        NSMutableURLRequest *request = [self downloadRequestForPath:@"" token:token];
        [[self->_downloadSession dataTaskWithRequest:request] resume];
        [[self->_callSession dataTaskWithRequest:request] resume];
    }];
}

#pragma mark - Transfers

// Any thread. A transfer with a task in flight completes through that task's
// cancel. One with none — waiting on a token refresh, or on a retry's delay
// after a task that already ended — settles here, at once: a cancel frees
// the caller's lane now, never when the refresh or the delay comes back
// (System/AGENTS.md). Whichever step runs next sees the flag.
- (void)cancelTransfer:(DropboxTransfer *)transfer {
    os_unfair_lock_lock(&_lock);
    transfer.cancelled = YES;
    NSURLSessionDataTask *task = transfer.task;
    os_unfair_lock_unlock(&_lock);
    if (task && task.state != NSURLSessionTaskStateCompleted) {
        [task cancel];
        return;
    }
    [self finishTransfer:transfer result:nil error:VibeCancelledError()];
}

// Exactly once per transfer, whichever path gets here first.
- (void)finishTransfer:(DropboxTransfer *)transfer result:(id)result error:(NSError *)error {
    os_unfair_lock_lock(&_lock);
    BOOL first = !transfer.finished;
    transfer.finished = YES;
    os_unfair_lock_unlock(&_lock);
    if (!first) {
        return;
    }
    NSError *closeError = nil;
    if (transfer.file && ![transfer.file closeAndReturnError:&closeError] && !error) {
        error = closeError;
    }
    transfer.file = nil;
    if (error && transfer.destination) {
        [NSFileManager.defaultManager removeItemAtURL:transfer.destination error:NULL];
    }
    transfer.completion(error ? nil : result, error);
}

// The transfer's task, unless a cancel came first. Under the lock, so a
// cancel either finds the task or is seen here.
- (BOOL)adoptTask:(NSURLSessionDataTask *)task forTransfer:(DropboxTransfer *)transfer {
    os_unfair_lock_lock(&_lock);
    BOOL cancelled = transfer.cancelled;
    if (!cancelled) {
        transfer.task = task;
    }
    os_unfair_lock_unlock(&_lock);
    return !cancelled;
}

- (dispatch_block_t)cancelBlockForTransfer:(DropboxTransfer *)transfer {
    __weak DropboxClient *weakSelf = self;
    return ^{
        [weakSelf cancelTransfer:transfer];
    };
}

#pragma mark - Ranged read

- (dispatch_block_t)readPath:(NSString *)path
                      offset:(uint64_t)offset
                      length:(uint64_t)length
                  completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    DropboxTransfer *read = [[DropboxTransfer alloc] init];
    read.path = path;
    // Weak: the transfer holds this block, and finishTransfer: holds the transfer.
    __weak DropboxTransfer *weakRead = read;
    read.completion = ^(id data, NSError *error) {
        completion(data, error ? nil : weakRead.metadata, error);
    };
    read.attempts = 1;
    [self startRead:read offset:offset length:length];
    return [self cancelBlockForTransfer:read];
}

- (void)startRead:(DropboxTransfer *)read offset:(uint64_t)offset length:(uint64_t)length {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            [self finishTransfer:read result:nil error:tokenError];
            return;
        }
        NSMutableURLRequest *request = [self downloadRequestForPath:read.path token:token];
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", offset, offset + length - 1]
       forHTTPHeaderField:@"Range"];
        NSURLSessionDataTask *task = [self->_callSession dataTaskWithRequest:request
                                                           completionHandler:^(NSData *data, NSURLResponse *response,
                                                                               NSError *error) {
            if (error) {
                [self finishTransfer:read result:nil
                               error:[error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled
                                       ? VibeCancelledError() : error];
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            // 200 is a server ignoring the range: the whole file, so cut it,
            // and a range past its end is nothing, never bytes from its start.
            if (http.statusCode == 206 || http.statusCode == 200) {
                read.metadata = VibeDropboxAPIResult(http);
                NSData *bytes = data ?: [NSData data];
                if (http.statusCode == 200) {
                    NSUInteger start = (NSUInteger)MIN((uint64_t)bytes.length, offset);
                    bytes = [bytes subdataWithRange:NSMakeRange(start,
                            (NSUInteger)MIN((uint64_t)(bytes.length - start), length))];
                }
                [self finishTransfer:read result:bytes error:nil];
                return;
            }
            [self handleFailureStatus:http.statusCode data:data
                           retryAfter:[http valueForHTTPHeaderField:@"Retry-After"]
                                token:token generation:generation refreshed:read.refreshed attempt:read.attempts
                               resend:^(BOOL nowRefreshed, NSInteger nextAttempt) {
                read.refreshed = nowRefreshed;
                read.attempts = nextAttempt;
                [self startRead:read offset:offset length:length];
            } fail:^(NSError *failure) {
                [self finishTransfer:read result:nil error:failure];
            }];
        }];
        if (![self adoptTask:task forTransfer:read]) {
            [self finishTransfer:read result:nil error:VibeCancelledError()];
            return;
        }
        [task resume];
    }];
}

#pragma mark - Download

- (dispatch_block_t)downloadPath:(NSString *)path
                           toURL:(NSURL *)destination
                        progress:(void (^)(uint64_t, int64_t, NSString *))progress
                      completion:(void (^)(NSDictionary *, NSError *))completion {
    DropboxTransfer *download = [[DropboxTransfer alloc] init];
    download.path = path;
    download.destination = destination;
    download.progress = progress;
    download.completion = completion;
    download.attempts = 1;
    [self startDownload:download];
    return [self cancelBlockForTransfer:download];
}

- (void)startDownload:(DropboxTransfer *)download {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            [self finishTransfer:download result:nil error:tokenError];
            return;
        }
        NSMutableURLRequest *request = [self downloadRequestForPath:download.path token:token];
        os_unfair_lock_lock(&self->_lock);
        uint64_t offset = download.bytesWritten;
        os_unfair_lock_unlock(&self->_lock);
        // A resend continues the file, never starts it over: a reader may
        // hold it open, and a new file would leave it waiting on one that
        // never grows.
        if (offset > 0) {
            [request setValue:[NSString stringWithFormat:@"bytes=%llu-", offset] forHTTPHeaderField:@"Range"];
        }
        NSURLSessionDataTask *task = [self->_downloadSession dataTaskWithRequest:request];
        download.accessToken = token;
        download.accountGeneration = generation;
        if (![self adoptTask:task forTransfer:download]) {
            [self finishTransfer:download result:nil error:VibeCancelledError()];
            return;
        }
        os_unfair_lock_lock(&self->_lock);
        self->_downloads[@(task.taskIdentifier)] = download;
        os_unfair_lock_unlock(&self->_lock);
        [task resume];
    }];
}

- (DropboxTransfer *)downloadForTask:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_lock);
    DropboxTransfer *download = _downloads[@(task.taskIdentifier)];
    os_unfair_lock_unlock(&_lock);
    return download;
}

// The delegate queue is serial, so a download's response, data and
// completion callbacks never overlap, and it alone writes the file.
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    DropboxTransfer *download = [self downloadForTask:dataTask];
    if (!download) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    download.status = http.statusCode;
    download.errorData = nil;
    download.skip = 0;
    // A ranged resend answers 206 from where the file stopped, or 200 with the
    // whole file from a server ignoring the range. A request with no range,
    // the first or one before any byte was written, takes only 200.
    uint64_t offset = download.bytesWritten;
    if (http.statusCode != 200 && !(http.statusCode == 206 && offset > 0)) {
        download.errorData = [NSMutableData data];
        download.retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSDictionary *metadata = VibeDropboxAPIResult(http);
    if (download.file) {
        // TRAP: a download by id answers whatever version is current, so a
        // resend after a re-upload would splice two versions into one file.
        // Every response must name the first one's rev; with none to compare,
        // nothing proves the bytes match, and the transfer fails the same way.
        NSString *pinned = VibeDropboxRevOf(download.metadata);
        NSString *rev = VibeDropboxRevOf(metadata);
        if (!pinned || ![rev isEqualToString:pinned]) {
            LogWarn(@"Dropbox: %@ changed during its download (rev %@, now %@)", download.path, pinned, rev);
            download.failure = VibeDropboxMakeError(VibeDropboxErrorFileChanged,
                                                    @"the file changed on Dropbox during its download");
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
        download.skip = http.statusCode == 200 ? offset : 0;
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    // Made once per transfer, at its first accepted response.
    download.metadata = metadata;
    download.size = VibeDropboxSizeOf(metadata);
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:download.destination error:NULL];
    if (![files createFileAtPath:download.destination.path contents:nil attributes:nil]) {
        download.failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSError *error = nil;
    download.file = [NSFileHandle fileHandleForWritingToURL:download.destination error:&error];
    download.failure = error;
    if (download.file && download.progress) {
        download.progress(0, download.size, VibeDropboxRevOf(download.metadata));
    }
    completionHandler(download.file ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    DropboxTransfer *download = [self downloadForTask:dataTask];
    if (download.errorData) {
        [download.errorData appendData:data];
        return;
    }
    if (!download.file || download.failure) {
        return;
    }
    if (download.skip > 0) {
        NSUInteger skipped = (NSUInteger)MIN((uint64_t)data.length, download.skip);
        download.skip -= skipped;
        data = [data subdataWithRange:NSMakeRange(skipped, data.length - skipped)];
        if (data.length == 0) {
            return;
        }
    }
    NSError *error = nil;
    if (![download.file writeData:data error:&error]) {
        download.failure = error;
        [dataTask cancel];
        return;
    }
    download.networkRetries = 0;
    os_unfair_lock_lock(&_lock);
    uint64_t written = download.bytesWritten += data.length;
    os_unfair_lock_unlock(&_lock);
    // After the write: a reader told of these bytes finds them on disk.
    if (download.progress) {
        download.progress(written, download.size, VibeDropboxRevOf(download.metadata));
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    os_unfair_lock_lock(&_lock);
    DropboxTransfer *download = _downloads[@(task.taskIdentifier)];
    [_downloads removeObjectForKey:@(task.taskIdentifier)];
    BOOL cancelled = download.cancelled;
    os_unfair_lock_unlock(&_lock);
    if (!download) {
        return;
    }
    if (cancelled) {
        [self finishTransfer:download result:nil error:VibeCancelledError()];
        return;
    }
    if (download.failure) {
        [self finishTransfer:download result:nil error:download.failure];
        return;
    }
    // Every byte is here: a resend would ask for bytes=<size>-, which 416s.
    BOOL whole = download.file && download.size >= 0 && download.bytesWritten == (uint64_t)download.size;
    if (error && whole && !download.errorData && VibeDropboxIsConnectionError(error)) {
        error = nil;
    }
    if (error) {
        if (download.file && download.networkRetries < kMaximumNetworkRetries && VibeDropboxIsConnectionError(error)) {
            download.networkRetries++;
            LogInfo(@"Dropbox: resuming %@ at byte %llu: %@", download.path, download.bytesWritten,
                    error.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self startDownload:download];
            });
            return;
        }
        [self finishTransfer:download result:nil error:error];
        return;
    }
    if (!download.errorData) {
        // A file of another length than its version's is not that version.
        NSError *mismatch = download.size < 0 || whole ? nil
                : VibeDropboxMakeError(VibeDropboxErrorAPI, @"the download's length differs from its file's size");
        if (mismatch) {
            LogWarn(@"Dropbox: %@ ended at byte %llu of %lld", download.path, download.bytesWritten, download.size);
        }
        [self finishTransfer:download result:download.metadata ?: @{} error:mismatch];
        return;
    }
    [self handleFailureStatus:download.status data:download.errorData retryAfter:download.retryAfter
                        token:download.accessToken generation:download.accountGeneration
                    refreshed:download.refreshed attempt:download.attempts
                       resend:^(BOOL nowRefreshed, NSInteger nextAttempt) {
        download.refreshed = nowRefreshed;
        download.attempts = nextAttempt;
        [self startDownload:download];
    } fail:^(NSError *failure) {
        [self finishTransfer:download result:nil error:failure];
    }];
}

@end
