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

typedef void (^VibeDropboxTokenWaiter)(NSString *_Nullable token, uint64_t accountGeneration,
                                       NSError *_Nullable error);

#pragma mark - Transfer state

// A download or a ranged read in flight. The cancel flag and the task are
// under the client's lock; the rest is the delegate queue's, per attempt.
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
// A download's only.
@property (nonatomic, copy, nullable) NSURL *destination;
@property (nonatomic) NSInteger status;
@property (nonatomic, nullable) NSDictionary *metadata;
@property (nonatomic, nullable) NSFileHandle *file;
@property (nonatomic, nullable) NSMutableData *errorData;
@property (nonatomic, copy, nullable) NSString *retryAfter;
@property (nonatomic, nullable) NSError *writeError;
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
    [self callEndpoint:@"users/get_current_account" arguments:nil
            completion:^(NSDictionary *result, NSError *error) {
        NSDictionary *name = result[@"name"];
        NSString *display = [name isKindOfClass:NSDictionary.class] ? name[@"display_name"] : nil;
        NSString *accountID = result[@"account_id"];
        if ([display isKindOfClass:NSString.class]) {
            os_unfair_lock_lock(&self->_lock);
            NSString *refresh = self->_refreshToken;
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
    if (error && transfer.destination) {
        [NSFileManager.defaultManager removeItemAtURL:transfer.destination error:NULL];
    }
    transfer.completion(result, error);
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
                  completion:(void (^)(NSData *, NSError *))completion {
    DropboxTransfer *read = [[DropboxTransfer alloc] init];
    read.path = path;
    read.completion = completion;
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
                      completion:(void (^)(NSDictionary *, NSError *))completion {
    DropboxTransfer *download = [[DropboxTransfer alloc] init];
    download.path = path;
    download.destination = destination;
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
        NSURLSessionDataTask *task = [self->_downloadSession dataTaskWithRequest:
                [self downloadRequestForPath:download.path token:token]];
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
// completion callbacks never overlap.
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
    download.metadata = nil;
    download.errorData = nil;
    download.writeError = nil;
    [download.file closeFile];
    download.file = nil;
    if (http.statusCode != 200) {
        download.errorData = [NSMutableData data];
        download.retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSString *result = [http valueForHTTPHeaderField:@"Dropbox-API-Result"];
    download.metadata = VibeJSONObject([result dataUsingEncoding:NSUTF8StringEncoding]);
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:download.destination error:NULL];
    if (![files createFileAtPath:download.destination.path contents:nil attributes:nil]) {
        download.writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSError *error = nil;
    download.file = [NSFileHandle fileHandleForWritingToURL:download.destination error:&error];
    download.writeError = error;
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
    if (!download.file) {
        return;
    }
    NSError *error = nil;
    if (![download.file writeData:data error:&error]) {
        download.writeError = error;
        [download.file closeFile];
        download.file = nil;
        [dataTask cancel];
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
    NSError *closeError = nil;
    if (download.file && ![download.file closeAndReturnError:&closeError]) {
        download.writeError = download.writeError ?: closeError;
    }
    download.file = nil;

    if (cancelled) {
        [self finishTransfer:download result:nil error:VibeCancelledError()];
        return;
    }
    if (download.writeError || error) {
        [self finishTransfer:download result:nil error:download.writeError ?: error];
        return;
    }
    if (download.status == 200) {
        [self finishTransfer:download result:download.metadata ?: @{} error:nil];
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
