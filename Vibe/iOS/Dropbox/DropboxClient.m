//
//  DropboxClient.m
//  Vibe (iOS)
//

#import "DropboxClientInternal.h"

#import <Security/Security.h>
#include <os/lock.h>

#import "DropboxRules.h"
#import "HTTPTransferRules.h"

NSErrorDomain const VibeDropboxErrorDomain = @"com.commonwealthrecordings.Vibe.Dropbox";
NSNotificationName const VibeDropboxAccountDidChangeNotification =
        @"VibeDropboxAccountDidChangeNotification";

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

BOOL VibeDropboxKeepsPart(NSError *error) {
    return ([error.domain isEqualToString:VibeDropboxErrorDomain] && error.code == VibeDropboxErrorCancelled)
            || VibeHTTPIsConnectionError(error);
}

// A transfer's state: the access token its attempt was sent with, that
// token's account generation, and whether an expired token was refreshed.
static NSString *const kStateToken = @"token";
static NSString *const kStateAccountGeneration = @"accountGeneration";
static NSString *const kStateRefreshed = @"refreshed";

// The metadata a content response carries in its Dropbox-API-Result header.
static NSDictionary *_Nullable VibeDropboxAPIResult(NSHTTPURLResponse *http) {
    return VibeJSONObject([[http valueForHTTPHeaderField:@"Dropbox-API-Result"] dataUsingEncoding:NSUTF8StringEncoding]);
}

typedef void (^VibeDropboxTokenWaiter)(NSString *_Nullable token, uint64_t accountGeneration,
                                       NSError *_Nullable error);

#pragma mark - Client

@interface DropboxClient () <ASWebAuthenticationPresentationContextProviding>
@end

@implementation DropboxClient {
    NSString *_appKey;
    NSString *_keychainService;

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

- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _appKey = [appKey copy];
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
        LogError(@"Dropbox: keychain write failed: %d", (int)status);
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
    uint64_t generation = _accountGeneration;
    os_unfair_lock_unlock(&_lock);
    [self saveRefreshToken:refreshToken accountID:accountID name:nil generation:generation];
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
        uint64_t generation = self->_accountGeneration;
        NSString *accountID = self->_accountIDValue;
        os_unfair_lock_unlock(&self->_lock);
        [self saveRefreshToken:refresh accountID:accountID name:nil generation:generation];
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
    LogInfo(@"Dropbox: signed out");
    // Revoking needs a live access token; a stale one is refreshed first so
    // the grant really ends on Dropbox's side, not only here.
    void (^revoke)(NSString *) = ^(NSString *token) {
        NSURL *url = [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:@"auth/token/revoke"]];
        [[self.callSession dataTaskWithRequest:[self requestForURL:url token:token]] resume];
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

// One ladder for every call Dropbox refused, the calls' and the transfers':
// an expired access token refreshes once and resends, any other 401 unlinks,
// a throttle waits and resends, and the rest fail with Dropbox's own words.
// Exactly one of resend and fail runs.
- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger attempt))resend
                       fail:(void (^)(NSError *error))fail {
    NSDictionary *body = VibeJSONObject(data);
    if (VibeDropboxIsExpiredAccessToken(status, body) && ![state[kStateRefreshed] boolValue]) {
        [self discardAccessToken:state[kStateToken]];
        state[kStateRefreshed] = @YES;
        resend(attempt);
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
        [self unlinkAccountGeneration:[state[kStateAccountGeneration] unsignedLongLongValue] reason:summary];
        fail(VibeDropboxMakeError(VibeDropboxErrorNotLinked, summary));
        return;
    }
    NSTimeInterval delay = VibeHTTPRetryDelay(status, retryAfter);
    if (delay >= 0 && attempt < kVibeHTTPMaximumAttempts) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * self.retryDelayScale * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            resend(attempt + 1);
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
    [[self.callSession dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        completion(VibeJSONObject(data), status, error);
    }] resume];
}

- (BOOL)hasFreshAccessTokenLocked {
    return _accessToken && _accessTokenExpiry - kAccessTokenMargin > CFAbsoluteTimeGetCurrent();
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
            if (!error && VibeDropboxIsRevokedGrant(status, body)) {
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
    [self callEndpoint:endpoint arguments:arguments state:[NSMutableDictionary dictionary] attempt:1
            completion:completion];
}

- (void)callEndpoint:(NSString *)endpoint
           arguments:(NSDictionary *)arguments
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
        NSMutableURLRequest *request = [self requestForURL:
                [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:endpoint]] token:token];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        // An endpoint without arguments takes the JSON null, not an empty body.
        request.HTTPBody = arguments
                ? [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL]
                : [@"null" dataUsingEncoding:NSUTF8StringEncoding];
        [[self.callSession dataTaskWithRequest:request
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
                                state:state attempt:attempt
                               resend:^(NSInteger nextAttempt) {
                [self callEndpoint:endpoint arguments:arguments state:state attempt:nextAttempt
                        completion:completion];
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
        [[self.downloadSession dataTaskWithRequest:request] resume];
        [[self.callSession dataTaskWithRequest:request] resume];
    }];
}

#pragma mark - Transfers

- (dispatch_block_t)downloadPath:(NSString *)path
                           toURL:(NSURL *)destination
                        progress:(void (^)(uint64_t, int64_t, NSString *))progress
                      completion:(void (^)(NSDictionary *, NSError *))completion {
    return [self downloadTarget:path toURL:destination progress:progress completion:completion];
}

- (dispatch_block_t)readPath:(NSString *)path
                      offset:(uint64_t)offset
                      length:(uint64_t)length
                  completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    return [self readTarget:path offset:offset length:length completion:completion];
}

// files/download by the target path, as the account. A transfer waiting on
// the refresh is settled at once by its cancel (HTTPTransferClient).
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
        completion([self downloadRequestForPath:target token:token], nil);
    }];
}

- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response {
    return VibeDropboxAPIResult(response);
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    return VibeDropboxRevOf(metadata);
}

- (int64_t)sizeOfMetadata:(NSDictionary *)metadata {
    return VibeDropboxSizeOf(metadata);
}

- (NSError *)errorWithCode:(VibeHTTPError)code description:(NSString *)description {
    switch (code) {
        case VibeHTTPErrorCancelled:
            return VibeDropboxMakeError(VibeDropboxErrorCancelled, description);
        case VibeHTTPErrorVersionChanged:
            return VibeDropboxMakeError(VibeDropboxErrorFileChanged, @"the file changed on Dropbox during its download");
        default:
            return VibeDropboxMakeError(VibeDropboxErrorAPI, description);
    }
}

- (BOOL)keepsPartAfterError:(NSError *)error {
    return VibeDropboxKeepsPart(error);
}

- (NSString *)logName {
    return @"Dropbox";
}

@end
