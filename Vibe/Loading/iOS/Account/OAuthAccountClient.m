//
//  OAuthAccountClient.m
//  Vibe (iOS)
//

#import "OAuthAccountClientInternal.h"

#import <Security/Security.h>
#include <os/lock.h>

#import "AccountRules.h"
#import "HTTPTransferRules.h"

NSErrorDomain const VibeAccountErrorDomain = @"com.commonwealthrecordings.Vibe.Account";
NSNotificationName const VibeAccountDidChangeNotification = @"VibeAccountDidChangeNotification";

// An access token this close to its expiry is refreshed instead of used.
static const NSTimeInterval kAccessTokenMargin = 60;
// A Keychain still locked is asked again no sooner than this.
static const NSTimeInterval kAccountLoadRetryInterval = 5;

static NSData *VibeRandomBytes(size_t count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    if (SecRandomCopyBytes(kSecRandomDefault, count, data.mutableBytes) != errSecSuccess) {
        arc4random_buf(data.mutableBytes, count);
    }
    return data;
}

// A call's or a transfer's state: the access token its attempt was sent
// with, that token's account generation, and whether an expired token was
// refreshed.
static NSString *const kStateToken = @"token";
static NSString *const kStateAccountGeneration = @"accountGeneration";
static NSString *const kStateRefreshed = @"refreshed";

typedef void (^VibeAccountTokenWaiter)(NSString *_Nullable token, uint64_t accountGeneration,
                                       NSError *_Nullable error);

@interface OAuthAccountClient () <ASWebAuthenticationPresentationContextProviding>
@end

@implementation OAuthAccountClient {
    NSString *_keychainService;

    os_unfair_lock _lock;
    NSString *_refreshToken;
    NSString *_accountIDValue;
    NSString *_accountNameValue;
    NSString *_accessToken;
    CFAbsoluteTime _accessTokenExpiry;
    // The refresh claim: nil when none is in flight, else its waiters.
    NSMutableArray<VibeAccountTokenWaiter> *_refreshWaiters;
    // Bumped by every sign-in and sign-out, so a refresh or a 401 that
    // belongs to the previous account can neither restore nor unlink it.
    uint64_t _accountGeneration;
    // Orders every Keychain write: a save checks its account generation and
    // writes inside it, and a delete waits for it. Not _lock, which no
    // Keychain IPC may run under.
    NSLock *_keychainLock;
    // The Keychain answered "locked" (a launch before first unlock): the
    // account is read again at the next use rather than taken as absent, at
    // most once per kAccountLoadRetryInterval, since every accessor asks.
    BOOL _accountLoadDeferred;
    CFAbsoluteTime _accountLoadRetryAt;
    BOOL _warmedUp;

    // Main thread: the sign-in in progress.
    ASWebAuthenticationSession *_webSession;
    ASPresentationAnchor _anchor;
}

- (instancetype)initWithClientID:(NSString *)clientID
                 keychainService:(NSString *)keychainService
                   configuration:(NSURLSessionConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _clientID = [clientID copy];
        _keychainService = [keychainService copy];
        _lock = OS_UNFAIR_LOCK_INIT;
        _keychainLock = [[NSLock alloc] init];
        [self loadAccount];
    }
    return self;
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
    NSDictionary *account = status == errSecSuccess ? VibeAccountJSONObject((__bridge_transfer NSData *)result) : nil;
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
        LogWarn(@"%@: keychain read failed: %d", self.logName, (int)status);
    }
    // At launch nothing is listening yet; a deferred read lands mid-session.
    if (adopt && wasDeferred) {
        LogInfo(@"%@: account read once the device unlocked", self.logName);
        [self postAccountDidChange];
    }
}

// Called with the lock NOT held; snapshot what to persist first, with the
// account generation it belongs to.
//
// TRAP: the generation is checked INSIDE the Keychain lock, and the write is
// made there too. A save checked outside it, or not at all, could land after
// a sign-out had deleted the item — SecItemDelete then SecItemAdd is two
// calls — and the next launch read the signed-out account as linked.
- (void)saveRefreshToken:(NSString *)refresh
               accountID:(NSString *)accountID
                    name:(NSString *)name
              generation:(uint64_t)generation {
    if (!_keychainService) {
        return;
    }
    [_keychainLock lock];
    os_unfair_lock_lock(&_lock);
    BOOL current = generation == _accountGeneration;
    os_unfair_lock_unlock(&_lock);
    if (!current) {
        [_keychainLock unlock];
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
    [_keychainLock unlock];
    if (status != errSecSuccess) {
        LogError(@"%@: keychain write failed: %d", self.logName, (int)status);
    }
}

- (void)deleteSavedAccount {
    if (_keychainService) {
        [_keychainLock lock];
        SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
        [_keychainLock unlock];
    }
}

- (void)postAccountDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VibeAccountDidChangeNotification object:self];
    });
}

// The grant is gone (revoked on the service's site, or the refresh refused):
// forget it, unless a newer sign-in or sign-out already moved past it.
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
    LogWarn(@"%@: account unlinked: %@", self.logName, reason);
    [self deleteSavedAccount];
    [self postAccountDidChange];
}

// Links an account: the sign-in's and the adopt's one road.
- (void)linkRefreshToken:(NSString *)refresh
             accessToken:(NSString *)access
               expiresIn:(NSTimeInterval)expiresIn
               accountID:(NSString *)accountID
                    name:(NSString *)name {
    os_unfair_lock_lock(&_lock);
    [self replaceAccountLockedWithRefreshToken:refresh accessToken:access expiresIn:expiresIn accountID:accountID];
    _accountNameValue = [name copy];
    uint64_t generation = _accountGeneration;
    NSString *savedID = _accountIDValue;
    os_unfair_lock_unlock(&_lock);
    [self saveRefreshToken:refresh accountID:savedID name:name generation:generation];
    [self postAccountDidChange];
}

- (void)adoptRefreshToken:(NSString *)refreshToken accountID:(NSString *)accountID {
    [self linkRefreshToken:refreshToken accessToken:nil expiresIn:0 accountID:accountID name:nil];
}

#pragma mark - Sign-in

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return _anchor;
}

- (void)signInWithPresentationAnchor:(ASPresentationAnchor)anchor
                          completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"main thread");
    // A build without the service's client id (a debug build's Google
    // Drive) has no sign-in page to show.
    if (_clientID.length == 0) {
        completion(VibeAccountMakeError(VibeAccountErrorSignInFailed, @"no client id in this build"));
        return;
    }
    [_webSession cancel];
    NSString *verifier = VibeAccountBase64URL(VibeRandomBytes(32));
    NSString *state = VibeAccountBase64URL(VibeRandomBytes(16));
    NSURL *url = [self authorizeURLWithCodeChallenge:VibeAccountCodeChallenge(verifier) state:state];

    __weak OAuthAccountClient *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OAuthAccountClient *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_webSession = nil;
                strongSelf->_anchor = nil;
            }
            completion(error);
        });
    };
    ASWebAuthenticationSession *session = [[ASWebAuthenticationSession alloc]
            initWithURL:url
      callbackURLScheme:[self callbackScheme]
      completionHandler:^(NSURL *callbackURL, NSError *error) {
        OAuthAccountClient *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (!callbackURL) {
            // Closing the sheet is the user's answer, not a failure to report.
            BOOL cancelled = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]
                    && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
            finish(cancelled ? nil : VibeAccountMakeError(VibeAccountErrorSignInFailed,
                                                          error.localizedDescription ?: @"sign-in failed"));
            return;
        }
        NSString *reason = nil;
        NSString *code = VibeAccountAuthorizationCode(callbackURL, state, &reason);
        if (!code) {
            finish(VibeAccountMakeError(VibeAccountErrorSignInFailed, reason ?: @"no authorization code"));
            return;
        }
        [strongSelf exchangeCode:code verifier:verifier completion:finish];
    }];
    session.presentationContextProvider = self;
    _anchor = anchor;
    _webSession = session;
    if (![session start]) {
        finish(VibeAccountMakeError(VibeAccountErrorSignInFailed, @"could not present sign-in"));
    }
}

- (void)exchangeCode:(NSString *)code
            verifier:(NSString *)verifier
          completion:(void (^)(NSError *))completion {
    NSDictionary *fields = @{
        @"code": code,
        @"grant_type": @"authorization_code",
        @"code_verifier": verifier,
        @"client_id": _clientID,
        @"redirect_uri": [self redirectURI],
    };
    [self postForm:fields toURL:[self tokenURL] completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *refresh = body[@"refresh_token"];
        NSString *access = body[@"access_token"];
        if (error || ![refresh isKindOfClass:NSString.class] || ![access isKindOfClass:NSString.class]) {
            completion(error ?: VibeAccountMakeError(VibeAccountErrorSignInFailed,
                                                     [self errorSummaryForStatus:status body:body]));
            return;
        }
        NSTimeInterval expiresIn = [body[@"expires_in"] doubleValue];
        // What the grant carries; a scope missing here is the service's app
        // settings, and every call that needs it is refused.
        LogInfo(@"%@: signed in, scopes: %@", self.logName, body[@"scope"] ?: @"(none listed)");
        NSString *accountID = [self accountIDOfTokenAnswer:body];
        if (accountID) {
            [self linkRefreshToken:refresh accessToken:access expiresIn:expiresIn accountID:accountID name:nil];
            [self refreshAccountNameWithCompletion:^{
                completion(nil);
            }];
            return;
        }
        // No account without its id, which names the mirror's directory.
        [self readIdentityWithAccessToken:access completion:^(NSString *name, NSString *identityID) {
            if (!identityID) {
                completion(VibeAccountMakeError(VibeAccountErrorSignInFailed, @"could not read the account"));
                return;
            }
            [self linkRefreshToken:refresh accessToken:access expiresIn:expiresIn accountID:identityID name:name];
            completion(nil);
        }];
    }];
}

// The identity call with the token the code exchange just granted, before
// any account holds it: no ladder.
- (void)readIdentityWithAccessToken:(NSString *)access
                         completion:(void (^)(NSString *_Nullable name, NSString *_Nullable accountID))completion {
    [[self.callSession dataTaskWithRequest:[self identityRequestWithAccessToken:access]
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *identity = status == 200 ? VibeAccountJSONObject(data) : nil;
        if (!identity) {
            LogWarn(@"%@: could not read the account: %@", self.logName,
                    error.localizedDescription ?: [self errorSummaryForStatus:status body:VibeAccountJSONObject(data)]);
            completion(nil, nil);
            return;
        }
        completion([self nameOfIdentity:identity], [self accountIDOfIdentity:identity]);
    }] resume];
}

// The display name for Settings. A failure leaves it nil and the account
// linked: the name is decoration.
- (void)refreshAccountNameWithCompletion:(dispatch_block_t)completion {
    os_unfair_lock_lock(&_lock);
    uint64_t generation = _accountGeneration;
    os_unfair_lock_unlock(&_lock);
    [self sendAuthorizedRequest:^NSMutableURLRequest *(NSString *accessToken) {
        return [self identityRequestWithAccessToken:accessToken];
    } completion:^(NSDictionary *result, NSError *error) {
        NSString *display = result ? [self nameOfIdentity:result] : nil;
        NSString *accountID = result ? [self accountIDOfIdentity:result] : nil;
        if (display) {
            os_unfair_lock_lock(&self->_lock);
            // Only the account it was asked for: an answer that outlived a
            // sign-out and the next sign-in would stamp that account with
            // this one's name and ID, and the mirror's directory is the ID.
            NSString *refresh = generation == self->_accountGeneration ? self->_refreshToken : nil;
            if (refresh) {
                self->_accountNameValue = display;
                if (accountID) {
                    self->_accountIDValue = accountID;
                }
            }
            NSString *savedID = self->_accountIDValue;
            os_unfair_lock_unlock(&self->_lock);
            if (refresh) {
                [self saveRefreshToken:refresh accountID:savedID name:display generation:generation];
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
    NSString *access = [self hasFreshAccessTokenLocked] ? _accessToken : nil;
    [self replaceAccountLockedWithRefreshToken:nil accessToken:nil expiresIn:0 accountID:nil];
    os_unfair_lock_unlock(&_lock);
    if (!refresh) {
        return;
    }
    [self deleteSavedAccount];
    [self postAccountDidChange];
    LogInfo(@"%@: signed out", self.logName);
    [self revokeRefreshToken:refresh accessToken:access];
}

#pragma mark - Access token

- (void)postForm:(NSDictionary<NSString *, NSString *> *)fields
           toURL:(NSURL *)url
      completion:(void (^)(NSDictionary *, NSInteger, NSError *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = VibeAccountFormBody(fields);
    [[self.callSession dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        completion(VibeAccountJSONObject(data), status, error);
    }] resume];
}

- (NSDictionary<NSString *, NSString *> *)refreshFormForToken:(NSString *)refresh {
    return @{@"grant_type": @"refresh_token", @"refresh_token": refresh, @"client_id": _clientID};
}

- (void)requestAccessTokenWithRefreshToken:(NSString *)refreshToken
                                completion:(void (^)(NSString *))completion {
    [self postForm:[self refreshFormForToken:refreshToken] toURL:[self tokenURL]
        completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *token = body[@"access_token"];
        completion([token isKindOfClass:NSString.class] ? token : nil);
    }];
}

- (BOOL)hasFreshAccessTokenLocked {
    return _accessToken && _accessTokenExpiry - kAccessTokenMargin > CFAbsoluteTimeGetCurrent();
}

// Single-flight: every caller arriving during a refresh waits on that one.
- (void)withAccessToken:(VibeAccountTokenWaiter)waiter {
    [self retryDeferredAccountLoad];
    os_unfair_lock_lock(&_lock);
    if (!_refreshToken) {
        os_unfair_lock_unlock(&_lock);
        waiter(nil, 0, VibeAccountMakeError(VibeAccountErrorNotLinked,
                                            [NSString stringWithFormat:@"no %@ account", self.logName]));
        return;
    }
    if ([self hasFreshAccessTokenLocked]) {
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
    [self postForm:[self refreshFormForToken:refresh] toURL:[self tokenURL]
        completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *token = body[@"access_token"];
        BOOL granted = !error && [token isKindOfClass:NSString.class];
        os_unfair_lock_lock(&self->_lock);
        NSArray<VibeAccountTokenWaiter> *waiters = self->_refreshWaiters;
        self->_refreshWaiters = nil;
        BOOL current = generation == self->_accountGeneration;
        if (granted && current) {
            self->_accessToken = token;
            self->_accessTokenExpiry = CFAbsoluteTimeGetCurrent() + [body[@"expires_in"] doubleValue];
        }
        os_unfair_lock_unlock(&self->_lock);

        NSError *failure = nil;
        if (!current) {
            failure = VibeAccountMakeError(VibeAccountErrorNotLinked, @"account changed during refresh");
        }
        else if (!granted) {
            NSString *summary = [self errorSummaryForStatus:status body:body];
            if (!error && VibeAccountIsRevokedGrant(status, body)) {
                [self unlinkAccountGeneration:generation reason:summary];
                failure = VibeAccountMakeError(VibeAccountErrorNotLinked, summary);
            }
            else {
                failure = error ?: VibeAccountMakeError(VibeAccountErrorAPI, summary);
            }
        }
        for (VibeAccountTokenWaiter each in waiters) {
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

#pragma mark - The ladder

// One ladder for every call the service refused, the calls' and the
// transfers': an expired access token refreshes once and resends, any other
// 401 unlinks, a throttle waits and resends, and the rest fail with the
// service's own words. Exactly one of resend and fail runs.
- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger attempt))resend
                       fail:(void (^)(NSError *error))fail {
    NSDictionary *body = VibeAccountJSONObject(data);
    if ([self isExpiredAccessTokenStatus:status body:body] && ![state[kStateRefreshed] boolValue]) {
        [self discardAccessToken:state[kStateToken]];
        state[kStateRefreshed] = @YES;
        resend(attempt);
        return;
    }
    NSString *summary = [self errorSummaryForStatus:status body:body];
    // A body that is not JSON is the service saying why in plain text: a 400
    // for a call's shape, or a scope the grant lacks.
    if (!body && data.length > 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        summary = [NSString stringWithFormat:@"%@: %@", summary,
                   text.length > 300 ? [text substringToIndex:300] : text];
    }
    if (status == 401) {
        [self unlinkAccountGeneration:[state[kStateAccountGeneration] unsignedLongLongValue] reason:summary];
        fail(VibeAccountMakeError(VibeAccountErrorNotLinked, summary));
        return;
    }
    NSInteger retryStatus = [self isThrottleStatus:status body:body] ? 429 : status;
    if ([self resendAfterStatus:retryStatus retryAfter:retryAfter attempt:attempt resend:resend]) {
        return;
    }
    LogWarn(@"%@: call failed: %@", self.logName, summary);
    fail(VibeAccountMakeError(VibeAccountErrorAPI, summary));
}

#pragma mark - Calls

- (NSMutableURLRequest *)authorizedRequestWithURL:(NSURL *)url accessToken:(NSString *)accessToken {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[@"Bearer " stringByAppendingString:accessToken] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (void)sendAuthorizedRequest:(NSMutableURLRequest *(^)(NSString *))makeRequest
                   completion:(void (^)(NSDictionary *, NSError *))completion {
    [self sendAuthorizedRequest:makeRequest state:[NSMutableDictionary dictionary] attempt:1 completion:completion];
}

- (void)sendAuthorizedRequest:(NSMutableURLRequest *(^)(NSString *))makeRequest
                        state:(NSMutableDictionary<NSString *, id> *)state
                      attempt:(NSInteger)attempt
                   completion:(void (^)(NSDictionary *, NSError *))completion {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }
        state[kStateToken] = token;
        state[kStateAccountGeneration] = @(generation);
        [[self.callSession dataTaskWithRequest:makeRequest(token)
                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 200) {
                completion(VibeAccountJSONObject(data) ?: @{}, nil);
                return;
            }
            [self handleFailureStatus:http.statusCode data:data
                           retryAfter:[http valueForHTTPHeaderField:@"Retry-After"]
                                state:state attempt:attempt
                               resend:^(NSInteger nextAttempt) {
                [self sendAuthorizedRequest:makeRequest state:state attempt:nextAttempt completion:completion];
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
        if (token) {
            [self warmUpConnectionsWithAccessToken:token];
        }
    }];
}

#pragma mark - Transfers

// The target's request, as the account. A transfer waiting on the refresh is
// settled at once by its cancel (HTTPTransferClient).
- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }
        state[kStateToken] = token;
        state[kStateAccountGeneration] = @(generation);
        completion([self transferRequestForTarget:target accessToken:token], nil);
    }];
}

- (NSError *)errorWithCode:(VibeHTTPError)code description:(NSString *)description {
    switch (code) {
        case VibeHTTPErrorCancelled:
            return VibeAccountMakeError(VibeAccountErrorCancelled, description);
        case VibeHTTPErrorVersionChanged:
            return VibeAccountMakeError(VibeAccountErrorFileChanged,
                                        [NSString stringWithFormat:@"the file changed on %@ during its download",
                                         self.logName]);
        default:
            return VibeAccountMakeError(VibeAccountErrorAPI, description);
    }
}

// A target names a file in the account, not a link.
- (NSString *)descriptionOfTarget:(id)target {
    return [target description];
}

#pragma mark - Hooks

- (NSURL *)authorizeURLWithCodeChallenge:(NSString *)codeChallenge state:(NSString *)state {
    NSAssert(NO, @"every subclass names its sign-in page");
    return [NSURL URLWithString:@"about:blank"];
}

- (NSString *)callbackScheme {
    NSAssert(NO, @"every subclass names its redirect");
    return @"";
}

- (NSString *)redirectURI {
    NSAssert(NO, @"every subclass names its redirect");
    return @"";
}

- (NSURL *)tokenURL {
    NSAssert(NO, @"every subclass names its token endpoint");
    return [NSURL URLWithString:@"about:blank"];
}

- (NSString *)accountIDOfTokenAnswer:(NSDictionary *)answer {
    return nil;
}

- (NSMutableURLRequest *)identityRequestWithAccessToken:(NSString *)accessToken {
    NSAssert(NO, @"every subclass names its identity call");
    return [NSMutableURLRequest requestWithURL:[self tokenURL]];
}

- (NSString *)accountIDOfIdentity:(NSDictionary *)identity {
    return nil;
}

- (NSString *)nameOfIdentity:(NSDictionary *)identity {
    return nil;
}

- (void)revokeRefreshToken:(NSString *)refreshToken accessToken:(NSString *)accessToken {
}

- (BOOL)isExpiredAccessTokenStatus:(NSInteger)status body:(NSDictionary *)body {
    return status == 401;
}

- (BOOL)isThrottleStatus:(NSInteger)status body:(NSDictionary *)body {
    return NO;
}

- (NSString *)errorSummaryForStatus:(NSInteger)status body:(NSDictionary *)body {
    return [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

- (NSMutableURLRequest *)transferRequestForTarget:(id)target accessToken:(NSString *)accessToken {
    NSAssert(NO, @"every subclass names its download");
    return [self authorizedRequestWithURL:[self tokenURL] accessToken:accessToken];
}

- (void)warmUpConnectionsWithAccessToken:(NSString *)accessToken {
}

@end
