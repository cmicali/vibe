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

static NSError *VibeDropboxMakeError(VibeDropboxError code, NSString *description) {
    return [NSError errorWithDomain:VibeDropboxErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

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

typedef void (^VibeDropboxTokenWaiter)(NSString *_Nullable token, uint64_t accountGeneration,
                                       NSError *_Nullable error);

#pragma mark - Download state

@interface DropboxDownload : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSURL *destination;
@property (nonatomic, copy) void (^completion)(NSDictionary *_Nullable, NSError *_Nullable);
@property (nonatomic) NSInteger attempts;
@property (nonatomic) BOOL refreshed;
// Under the client's lock.
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finished;
@property (nonatomic, nullable) NSURLSessionDataTask *task;
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic) uint64_t accountGeneration;
// The delegate queue's, per attempt: the response, then the body.
@property (nonatomic) NSInteger status;
@property (nonatomic, nullable) NSDictionary *metadata;
@property (nonatomic, nullable) NSFileHandle *file;
@property (nonatomic, nullable) NSMutableData *errorData;
@property (nonatomic, copy, nullable) NSString *retryAfter;
@property (nonatomic, nullable) NSError *writeError;
@end

@implementation DropboxDownload
@end

// A ranged read in flight: the task to cancel, and whether a cancel came
// before there was one. Under the client's lock.
@interface DropboxRead : NSObject
@property (nonatomic) BOOL cancelled;
@property (nonatomic, nullable) NSURLSessionDataTask *task;
@end

@implementation DropboxRead
@end

#pragma mark - Client

@interface DropboxClient () <NSURLSessionDataDelegate,
                             ASWebAuthenticationPresentationContextProviding>
@end

@implementation DropboxClient {
    NSString *_appKey;
    NSString *_keychainService;
    NSURLSession *_session;

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
    NSMutableDictionary<NSNumber *, DropboxDownload *> *_downloads;

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
        _lock = OS_UNFAIR_LOCK_INIT;
        _downloads = [NSMutableDictionary dictionary];
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.name = @"com.commonwealthrecordings.Vibe.dropbox";
        // TRAP: a delegate session retains its delegate until invalidated.
        // The client lives as long as the app, so this is never broken.
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:delegateQueue];
        [self loadAccount];
    }
    return self;
}

#pragma mark - Account

- (BOOL)isLinked {
    os_unfair_lock_lock(&_lock);
    BOOL linked = _refreshToken != nil;
    os_unfair_lock_unlock(&_lock);
    return linked;
}

- (NSString *)accountID {
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

- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: _keychainService,
        (__bridge id)kSecAttrAccount: @"account",
    };
}

- (void)loadAccount {
    if (!_keychainService) {
        return;
    }
    NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (status != errSecItemNotFound) {
            LogWarn(@"Dropbox: keychain read failed: %d", (int)status);
        }
        return;
    }
    NSDictionary *account = VibeJSONObject((__bridge_transfer NSData *)result);
    NSString *refresh = account[@"refresh_token"];
    if (![refresh isKindOfClass:NSString.class] || refresh.length == 0) {
        return;
    }
    _refreshToken = refresh;
    _accountIDValue = account[@"account_id"];
    _accountNameValue = account[@"name"];
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
        _refreshToken = nil;
        _accessToken = nil;
        _accountIDValue = nil;
        _accountNameValue = nil;
        _accountGeneration++;
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
    _accountGeneration++;
    _refreshToken = [refreshToken copy];
    _accessToken = nil;
    _accountIDValue = [accountID copy];
    _accountNameValue = nil;
    os_unfair_lock_unlock(&_lock);
    [self saveRefreshToken:refreshToken accountID:accountID name:nil];
    [self postAccountDidChange];
}

- (void)expireAccessToken {
    os_unfair_lock_lock(&_lock);
    _accessTokenExpiry = 0;
    os_unfair_lock_unlock(&_lock);
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
            BOOL cancelled = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]
                    && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
            finish(cancelled ? VibeDropboxMakeError(VibeDropboxErrorCancelled, @"sign-in cancelled")
                             : VibeDropboxMakeError(VibeDropboxErrorSignInFailed,
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
        NSString *accountID = body[@"account_id"];
        if (error || ![refresh isKindOfClass:NSString.class] || ![access isKindOfClass:NSString.class]) {
            completion(error ?: VibeDropboxMakeError(VibeDropboxErrorSignInFailed,
                                                 VibeDropboxErrorSummary(status, body)));
            return;
        }
        os_unfair_lock_lock(&self->_lock);
        self->_accountGeneration++;
        self->_refreshToken = refresh;
        self->_accessToken = access;
        self->_accessTokenExpiry = CFAbsoluteTimeGetCurrent() + [body[@"expires_in"] doubleValue];
        self->_accountIDValue = [accountID isKindOfClass:NSString.class] ? accountID : nil;
        self->_accountNameValue = nil;
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
    NSString *access = _accessToken;
    _refreshToken = nil;
    _accessToken = nil;
    _accountIDValue = nil;
    _accountNameValue = nil;
    _accountGeneration++;
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
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:@"auth/token/revoke"]]];
        request.HTTPMethod = @"POST";
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [[self->_session dataTaskWithRequest:request] resume];
    };
    if (access) {
        revoke(access);
        return;
    }
    [self postTokenForm:@{@"grant_type": @"refresh_token", @"refresh_token": refresh, @"client_id": _appKey}
             completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        NSString *token = body[@"access_token"];
        if ([token isKindOfClass:NSString.class]) {
            revoke(token);
        }
    }];
}

#pragma mark - Access token

- (void)postTokenForm:(NSDictionary<NSString *, NSString *> *)fields
           completion:(void (^)(NSDictionary *_Nullable body, NSInteger status, NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:VIBE_DROPBOX_TOKEN_URL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = VibeDropboxFormBody(fields);
    [[_session dataTaskWithRequest:request
                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        completion(VibeJSONObject(data), status, error);
    }] resume];
}

// Single-flight: every caller arriving during a refresh waits on that one.
- (void)withAccessToken:(VibeDropboxTokenWaiter)waiter {
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
    NSDictionary *fields = @{@"grant_type": @"refresh_token", @"refresh_token": refresh, @"client_id": _appKey};
    [self postTokenForm:fields completion:^(NSDictionary *body, NSInteger status, NSError *error) {
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
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:endpoint]]];
        request.HTTPMethod = @"POST";
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        // An endpoint without arguments takes the JSON null, not an empty body.
        request.HTTPBody = arguments
                ? [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL]
                : [@"null" dataUsingEncoding:NSUTF8StringEncoding];
        [[self->_session dataTaskWithRequest:request
                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSDictionary *body = VibeJSONObject(data);
            if (http.statusCode == 200) {
                completion(body ?: @{}, nil);
                return;
            }
            if (VibeDropboxIsExpiredAccessToken(http.statusCode, body) && !refreshed) {
                [self discardAccessToken:token];
                [self callEndpoint:endpoint arguments:arguments attempt:attempt refreshed:YES completion:completion];
                return;
            }
            if (http.statusCode == 401) {
                [self unlinkAccountGeneration:generation reason:VibeDropboxErrorSummary(http.statusCode, body)];
                completion(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, VibeDropboxErrorSummary(http.statusCode, body)));
                return;
            }
            NSTimeInterval delay = VibeDropboxRetryDelay(http.statusCode,
                                                         [http valueForHTTPHeaderField:@"Retry-After"]);
            if (delay >= 0 && attempt < kMaximumAttempts) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self callEndpoint:endpoint arguments:arguments attempt:attempt + 1
                             refreshed:refreshed completion:completion];
                });
                return;
            }
            NSString *summary = VibeDropboxErrorSummary(http.statusCode, body);
            // A 400 is Dropbox refusing the call's shape, and it says why in
            // plain text, not JSON.
            if (!body && data.length > 0) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                summary = [NSString stringWithFormat:@"%@: %@", summary,
                           text.length > 300 ? [text substringToIndex:300] : text];
            }
            LogWarn(@"Dropbox: %@ failed: %@", endpoint, summary);
            completion(nil, VibeDropboxMakeError(VibeDropboxErrorAPI, summary));
        }] resume];
    }];
}

#pragma mark - Ranged read

- (dispatch_block_t)readPath:(NSString *)path
                      offset:(uint64_t)offset
                      length:(uint64_t)length
                  completion:(void (^)(NSData *, NSError *))completion {
    DropboxRead *read = [[DropboxRead alloc] init];
    [self readPath:path offset:offset length:length attempt:1 refreshed:NO state:read completion:completion];
    __weak DropboxClient *weakSelf = self;
    return ^{
        DropboxClient *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_lock);
        read.cancelled = YES;
        NSURLSessionDataTask *task = read.task;
        os_unfair_lock_unlock(&strongSelf->_lock);
        [task cancel];
    };
}

- (void)readPath:(NSString *)path
          offset:(uint64_t)offset
          length:(uint64_t)length
         attempt:(NSInteger)attempt
       refreshed:(BOOL)refreshed
           state:(DropboxRead *)read
      completion:(void (^)(NSData *, NSError *))completion {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:[VIBE_DROPBOX_CONTENT_BASE stringByAppendingString:@"files/download"]]];
        request.HTTPMethod = @"POST";
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:VibeDropboxAPIArgHeader(@{@"path": path}) forHTTPHeaderField:@"Dropbox-API-Arg"];
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", offset, offset + length - 1]
       forHTTPHeaderField:@"Range"];
        NSURLSessionDataTask *task = [self->_session dataTaskWithRequest:request
                                                       completionHandler:^(NSData *data, NSURLResponse *response,
                                                                           NSError *error) {
            if (error) {
                completion(nil, [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled
                        ? VibeDropboxMakeError(VibeDropboxErrorCancelled, @"read cancelled") : error);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            // 200 is a server ignoring the range: the whole file, so cut it.
            if (http.statusCode == 206 || http.statusCode == 200) {
                NSData *bytes = data ?: [NSData data];
                if (http.statusCode == 200 && bytes.length > offset) {
                    bytes = [bytes subdataWithRange:NSMakeRange((NSUInteger)offset,
                            (NSUInteger)MIN((uint64_t)bytes.length - offset, length))];
                }
                completion(bytes, nil);
                return;
            }
            NSDictionary *body = VibeJSONObject(data);
            if (VibeDropboxIsExpiredAccessToken(http.statusCode, body) && !refreshed) {
                [self discardAccessToken:token];
                [self readPath:path offset:offset length:length attempt:attempt refreshed:YES
                         state:read completion:completion];
                return;
            }
            if (http.statusCode == 401) {
                [self unlinkAccountGeneration:generation reason:VibeDropboxErrorSummary(http.statusCode, body)];
                completion(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked,
                                                     VibeDropboxErrorSummary(http.statusCode, body)));
                return;
            }
            NSTimeInterval delay = VibeDropboxRetryDelay(http.statusCode,
                                                         [http valueForHTTPHeaderField:@"Retry-After"]);
            if (delay >= 0 && attempt < kMaximumAttempts) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self readPath:path offset:offset length:length attempt:attempt + 1 refreshed:refreshed
                             state:read completion:completion];
                });
                return;
            }
            completion(nil, VibeDropboxMakeError(VibeDropboxErrorAPI, VibeDropboxErrorSummary(http.statusCode, body)));
        }];
        os_unfair_lock_lock(&self->_lock);
        BOOL cancelled = read.cancelled;
        if (!cancelled) {
            read.task = task;
        }
        os_unfair_lock_unlock(&self->_lock);
        if (cancelled) {
            completion(nil, VibeDropboxMakeError(VibeDropboxErrorCancelled, @"read cancelled"));
            return;
        }
        [task resume];
    }];
}

#pragma mark - Download

- (dispatch_block_t)downloadPath:(NSString *)path
                           toURL:(NSURL *)destination
                      completion:(void (^)(NSDictionary *, NSError *))completion {
    DropboxDownload *download = [[DropboxDownload alloc] init];
    download.path = path;
    download.destination = destination;
    download.completion = completion;
    download.attempts = 1;
    [self startDownload:download];
    __weak DropboxClient *weakSelf = self;
    return ^{
        [weakSelf cancelDownload:download];
    };
}

- (void)cancelDownload:(DropboxDownload *)download {
    os_unfair_lock_lock(&_lock);
    download.cancelled = YES;
    NSURLSessionDataTask *task = download.task;
    os_unfair_lock_unlock(&_lock);
    // With no task yet, whichever step runs next sees the flag and finishes.
    [task cancel];
}

// Exactly once per download, whichever path gets here first.
- (void)finishDownload:(DropboxDownload *)download metadata:(NSDictionary *)metadata error:(NSError *)error {
    os_unfair_lock_lock(&_lock);
    BOOL first = !download.finished;
    download.finished = YES;
    os_unfair_lock_unlock(&_lock);
    if (!first) {
        return;
    }
    if (error) {
        [NSFileManager.defaultManager removeItemAtURL:download.destination error:NULL];
    }
    download.completion(metadata, error);
}

- (void)startDownload:(DropboxDownload *)download {
    [self withAccessToken:^(NSString *token, uint64_t generation, NSError *tokenError) {
        if (tokenError) {
            [self finishDownload:download metadata:nil error:tokenError];
            return;
        }
        NSString *argument = VibeDropboxAPIArgHeader(@{@"path": download.path});
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:[VIBE_DROPBOX_CONTENT_BASE stringByAppendingString:@"files/download"]]];
        request.HTTPMethod = @"POST";
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:argument forHTTPHeaderField:@"Dropbox-API-Arg"];

        os_unfair_lock_lock(&self->_lock);
        BOOL cancelled = download.cancelled;
        NSURLSessionDataTask *task = nil;
        if (!cancelled) {
            task = [self->_session dataTaskWithRequest:request];
            download.task = task;
            download.accessToken = token;
            download.accountGeneration = generation;
            self->_downloads[@(task.taskIdentifier)] = download;
        }
        os_unfair_lock_unlock(&self->_lock);
        if (cancelled) {
            [self finishDownload:download metadata:nil
                           error:VibeDropboxMakeError(VibeDropboxErrorCancelled, @"download cancelled")];
            return;
        }
        [task resume];
    }];
}

- (DropboxDownload *)downloadForTask:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_lock);
    DropboxDownload *download = _downloads[@(task.taskIdentifier)];
    os_unfair_lock_unlock(&_lock);
    return download;
}

// The delegate queue is serial, so a download's response, data and
// completion callbacks never overlap.
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    DropboxDownload *download = [self downloadForTask:dataTask];
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
    DropboxDownload *download = [self downloadForTask:dataTask];
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
    DropboxDownload *download = _downloads[@(task.taskIdentifier)];
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
        [self finishDownload:download metadata:nil
                       error:VibeDropboxMakeError(VibeDropboxErrorCancelled, @"download cancelled")];
        return;
    }
    if (download.writeError) {
        [self finishDownload:download metadata:nil error:download.writeError];
        return;
    }
    if (error) {
        [self finishDownload:download metadata:nil error:error];
        return;
    }
    NSInteger status = download.status;
    NSDictionary *errorBody = VibeJSONObject(download.errorData);
    if (status == 200) {
        [self finishDownload:download metadata:download.metadata ?: @{} error:nil];
        return;
    }
    if (VibeDropboxIsExpiredAccessToken(status, errorBody) && !download.refreshed) {
        download.refreshed = YES;
        [self discardAccessToken:download.accessToken];
        [self startDownload:download];
        return;
    }
    if (status == 401) {
        [self unlinkAccountGeneration:download.accountGeneration
                               reason:VibeDropboxErrorSummary(status, errorBody)];
        [self finishDownload:download metadata:nil
                       error:VibeDropboxMakeError(VibeDropboxErrorNotLinked,
                                              VibeDropboxErrorSummary(status, errorBody))];
        return;
    }
    NSTimeInterval delay = VibeDropboxRetryDelay(status, download.retryAfter);
    if (delay >= 0 && download.attempts < kMaximumAttempts) {
        download.attempts++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self startDownload:download];
        });
        return;
    }
    NSString *summary = VibeDropboxErrorSummary(status, errorBody);
    LogWarn(@"Dropbox: download failed: %@", summary);
    [self finishDownload:download metadata:nil error:VibeDropboxMakeError(VibeDropboxErrorAPI, summary)];
}


@end
