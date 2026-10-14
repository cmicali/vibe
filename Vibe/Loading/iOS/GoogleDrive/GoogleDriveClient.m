//
//  GoogleDriveClient.m
//  Vibe (iOS)
//

#import "GoogleDriveClient.h"

#include <os/lock.h>

#import "GoogleDriveRules.h"
#import "OAuthAccountClientInternal.h"

NSString *const VibeGoogleDriveKeychainService = @"com.commonwealthrecordings.Vibe.googledrive";
NSString *const VibeGoogleDriveClientIDInfoKey = @"VibeGoogleDriveClientID";

// A transfer's state: the lookup its attempt was sent with.
static NSString *const kStateLookup = @"lookup";
// A first attempt reuses a lookup this young: a download and its tail read
// start together, and a tag parse reads about three ranges in a second. A
// resend never reuses one.
static const NSTimeInterval kLookupReuseSeconds = 5;
// Past this many kept lookups, the stale ones go.
static const NSUInteger kLookupsKept = 256;

@implementation GoogleDriveClient {
    os_unfair_lock _lookupLock;
    // Each file's last lookup, by id, with "lookedUp": the system's uptime
    // when it was sent. Under the lock.
    NSMutableDictionary<NSString *, NSDictionary *> *_lookups;
    // The lookup claim: each file's waiters while its lookup is in flight.
    // Under the lock.
    NSMutableDictionary<NSString *, NSMutableArray *> *_lookupWaiters;
}

- (instancetype)initWithClientID:(NSString *)clientID
                 keychainService:(NSString *)keychainService
                   configuration:(NSURLSessionConfiguration *)configuration {
    self = [super initWithClientID:clientID keychainService:keychainService configuration:configuration];
    if (self) {
        _lookupLock = OS_UNFAIR_LOCK_INIT;
        _lookups = [NSMutableDictionary dictionary];
        _lookupWaiters = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Calls

- (NSMutableURLRequest *)requestForURL:(NSURL *)url token:(NSString *)token {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (void)getPath:(NSString *)path
          query:(NSDictionary<NSString *, NSString *> *)query
     completion:(void (^)(NSDictionary *, NSError *))completion {
    NSURL *url = VibeGoogleDriveURL(path, query);
    [self sendAuthorizedRequest:^NSMutableURLRequest *(NSString *accessToken) {
        return [self requestForURL:url token:accessToken];
    } completion:completion];
}

#pragma mark - The lookup

// The file's size, version and date: the last lookup while it is young and
// `fresh` is NO, else a new one. Single-flight: a caller arriving during a
// lookup waits on that one.
- (void)lookUpFileID:(NSString *)fileID
               fresh:(BOOL)fresh
          completion:(void (^)(NSDictionary *_Nullable file, NSError *_Nullable error))completion {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lookupLock);
    NSDictionary *last = fresh ? nil : _lookups[fileID];
    if (last && now - [last[@"lookedUp"] doubleValue] < kLookupReuseSeconds) {
        os_unfair_lock_unlock(&_lookupLock);
        completion(last, nil);
        return;
    }
    NSMutableArray *waiters = _lookupWaiters[fileID];
    BOOL owner = waiters == nil;
    if (owner) {
        waiters = _lookupWaiters[fileID] = [NSMutableArray array];
    }
    [waiters addObject:[completion copy]];
    os_unfair_lock_unlock(&_lookupLock);
    if (!owner) {
        return;
    }
    [self getPath:[@"files/" stringByAppendingString:fileID]
            query:@{@"fields": VIBE_GOOGLE_DRIVE_LOOKUP_FIELDS}
       completion:^(NSDictionary *result, NSError *error) {
        NSMutableDictionary *file = [result mutableCopy];
        file[@"lookedUp"] = @(now);
        os_unfair_lock_lock(&self->_lookupLock);
        NSArray *settled = self->_lookupWaiters[fileID];
        [self->_lookupWaiters removeObjectForKey:fileID];
        if (file) {
            if (self->_lookups.count >= kLookupsKept) {
                for (NSString *key in self->_lookups.allKeys) {
                    if (now - [self->_lookups[key][@"lookedUp"] doubleValue] >= kLookupReuseSeconds) {
                        [self->_lookups removeObjectForKey:key];
                    }
                }
            }
            self->_lookups[fileID] = file;
        }
        os_unfair_lock_unlock(&self->_lookupLock);
        for (void (^waiter)(NSDictionary *, NSError *) in settled) {
            waiter(file, error);
        }
    }];
}

#pragma mark - Transfers

// Every attempt is looked up first. A resend looks again, so its bytes
// continue the first response's only while the version still matches. A
// transfer waiting on the lookup is settled at once by its cancel
// (HTTPTransferClient).
- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    if (![target isKindOfClass:NSString.class]) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"not a Google Drive file"));
        return;
    }
    BOOL resend = state[kStateLookup] != nil;
    [self lookUpFileID:target fresh:resend completion:^(NSDictionary *file, NSError *error) {
        if (!file) {
            completion(nil, error);
            return;
        }
        state[kStateLookup] = file;
        [super makeRequestForTarget:target state:state completion:completion];
    }];
}

// TRAP: identity encoding. With none named the session asks for gzip, and a
// range's offsets would stop matching the file's bytes.
- (void)makeRequestForTarget:(id)target
                 accessToken:(NSString *)accessToken
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    NSURL *url = VibeGoogleDriveURL([@"files/" stringByAppendingString:target], @{@"alt": @"media"});
    NSMutableURLRequest *request = [self requestForURL:url token:accessToken];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    completion(request, nil);
}

- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response
                               state:(NSMutableDictionary<NSString *, id> *)state {
    NSDictionary *headers = [super metadataOfResponse:response state:state];
    NSDictionary *lookup = state[kStateLookup];
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    int64_t size = [super sizeOfMetadata:headers];
    if (size >= 0) {
        metadata[@"size"] = @(size);
    }
    NSString *version = VibeGoogleDriveVersionOf(lookup);
    if (version && size >= 0 && size == VibeGoogleDriveSizeOf(lookup)) {
        metadata[@"version"] = version;
    }
    metadata[@"modifiedTime"] = lookup[@"modifiedTime"];
    return metadata;
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    NSString *version = metadata[@"version"];
    return [version isKindOfClass:NSString.class] ? version : nil;
}

#pragma mark - The account's hooks

- (NSURL *)authorizeURLWithCodeChallenge:(NSString *)codeChallenge state:(NSString *)state {
    return VibeGoogleDriveAuthorizeURL(self.clientID, codeChallenge, state);
}

- (NSString *)callbackScheme {
    return VibeGoogleDriveCallbackScheme(self.clientID);
}

- (NSString *)redirectURI {
    return VibeGoogleDriveRedirectURI(self.clientID);
}

- (NSURL *)tokenURL {
    return [NSURL URLWithString:VIBE_GOOGLE_DRIVE_TOKEN_URL];
}

// The user's permissionId: stable, opaque, and no email address on disk.
- (NSMutableURLRequest *)identityRequestWithAccessToken:(NSString *)accessToken {
    return [self requestForURL:VibeGoogleDriveURL(@"about", @{@"fields": @"user(displayName,emailAddress,permissionId)"})
                         token:accessToken];
}

- (NSString *)accountIDOfIdentity:(NSDictionary *)identity {
    NSDictionary *user = [identity[@"user"] isKindOfClass:NSDictionary.class] ? identity[@"user"] : nil;
    NSString *permissionID = user[@"permissionId"];
    return [permissionID isKindOfClass:NSString.class] && permissionID.length > 0 ? permissionID : nil;
}

// The address tells two Google accounts apart, where a display name often
// cannot.
- (NSString *)nameOfIdentity:(NSDictionary *)identity {
    NSDictionary *user = [identity[@"user"] isKindOfClass:NSDictionary.class] ? identity[@"user"] : nil;
    NSString *email = user[@"emailAddress"];
    if ([email isKindOfClass:NSString.class] && email.length > 0) {
        return email;
    }
    NSString *display = user[@"displayName"];
    return [display isKindOfClass:NSString.class] && display.length > 0 ? display : nil;
}

// Google revokes a grant by its refresh token, so no access token is needed.
- (void)revokeRefreshToken:(NSString *)refreshToken accessToken:(NSString *)accessToken {
    [self postForm:@{@"token": refreshToken} toURL:[NSURL URLWithString:VIBE_GOOGLE_DRIVE_REVOKE_URL]
        completion:^(NSDictionary *body, NSInteger status, NSError *error) {
        if (status != 200) {
            LogWarn(@"Google Drive: revocation failed: %@",
                    error.localizedDescription ?: VibeGoogleDriveErrorSummary(status, body));
        }
    }];
}

- (BOOL)isThrottleStatus:(NSInteger)status body:(NSDictionary *)body {
    return VibeGoogleDriveIsThrottle(status, body);
}

- (NSString *)errorSummaryForStatus:(NSInteger)status body:(NSDictionary *)body {
    return VibeGoogleDriveErrorSummary(status, body);
}

// One small call on each session: a session's connections are its own, and
// the download and its tail ride different sessions.
- (void)warmUpConnectionsWithAccessToken:(NSString *)accessToken {
    NSMutableURLRequest *request = [self requestForURL:VibeGoogleDriveURL(@"files/root", @{@"fields": @"id"})
                                                 token:accessToken];
    [[self.downloadSession dataTaskWithRequest:request] resume];
    [[self.callSession dataTaskWithRequest:request] resume];
}

- (NSString *)logName {
    return @"Google Drive";
}

@end
