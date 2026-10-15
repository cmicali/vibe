//
//  DropboxClient.m
//  Vibe (iOS)
//

#import "DropboxClientInternal.h"

#import "DropboxRules.h"

NSString *const VibeDropboxKeychainService = @"com.commonwealthrecordings.Vibe.dropbox";
NSString *const VibeDropboxAppKeyInfoKey = @"VibeDropboxAppKey";

@implementation DropboxClient

- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration {
    return [super initWithClientID:appKey keychainService:keychainService configuration:configuration];
}

#pragma mark - Requests

// Every Dropbox call is a POST.
- (NSMutableURLRequest *)requestForURL:(NSURL *)url token:(NSString *)token {
    NSMutableURLRequest *request = [self authorizedRequestWithURL:url accessToken:token];
    request.HTTPMethod = @"POST";
    return request;
}

- (NSMutableURLRequest *)downloadRequestForPath:(NSString *)path token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:[VIBE_DROPBOX_CONTENT_BASE stringByAppendingString:@"files/download"]];
    NSMutableURLRequest *request = [self requestForURL:url token:token];
    [request setValue:VibeDropboxAPIArgHeader(@{@"path": path}) forHTTPHeaderField:@"Dropbox-API-Arg"];
    return request;
}

- (NSMutableURLRequest *)requestForEndpoint:(NSString *)endpoint
                                  arguments:(NSDictionary *)arguments
                                      token:(NSString *)token {
    NSMutableURLRequest *request = [self requestForURL:
            [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:endpoint]] token:token];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    // An endpoint without arguments takes the JSON null, not an empty body.
    request.HTTPBody = arguments
            ? [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL]
            : [@"null" dataUsingEncoding:NSUTF8StringEncoding];
    return request;
}

- (void)callEndpoint:(NSString *)endpoint
           arguments:(NSDictionary *)arguments
          completion:(void (^)(NSDictionary *, NSError *))completion {
    [self sendAuthorizedRequest:^NSMutableURLRequest *(NSString *accessToken) {
        return [self requestForEndpoint:endpoint arguments:arguments token:accessToken];
    } completion:completion];
}

#pragma mark - The account's hooks

- (NSURL *)authorizeURLWithCodeChallenge:(NSString *)codeChallenge state:(NSString *)state {
    return VibeDropboxAuthorizeURL(self.clientID, codeChallenge, state);
}

- (NSString *)callbackScheme {
    return VibeDropboxCallbackScheme(self.clientID);
}

- (NSString *)redirectURI {
    return VibeDropboxRedirectURI(self.clientID);
}

- (NSURL *)tokenURL {
    return [NSURL URLWithString:VIBE_DROPBOX_TOKEN_URL];
}

- (NSString *)accountIDOfTokenAnswer:(NSDictionary *)answer {
    NSString *accountID = answer[@"account_id"];
    return [accountID isKindOfClass:NSString.class] ? accountID : nil;
}

- (NSMutableURLRequest *)identityRequestWithAccessToken:(NSString *)accessToken {
    return [self requestForEndpoint:@"users/get_current_account" arguments:nil token:accessToken];
}

- (NSString *)accountIDOfIdentity:(NSDictionary *)identity {
    NSString *accountID = identity[@"account_id"];
    return [accountID isKindOfClass:NSString.class] ? accountID : nil;
}

- (NSString *)nameOfIdentity:(NSDictionary *)identity {
    NSDictionary *name = identity[@"name"];
    NSString *display = [name isKindOfClass:NSDictionary.class] ? name[@"display_name"] : nil;
    return [display isKindOfClass:NSString.class] ? display : nil;
}

// Revoking needs a live access token; a stale one is refreshed first so the
// grant really ends on Dropbox's side, not only here.
- (void)revokeRefreshToken:(NSString *)refreshToken accessToken:(NSString *)accessToken {
    void (^revoke)(NSString *) = ^(NSString *token) {
        NSURL *url = [NSURL URLWithString:[VIBE_DROPBOX_API_BASE stringByAppendingString:@"auth/token/revoke"]];
        [[self.callSession dataTaskWithRequest:[self requestForURL:url token:token]] resume];
    };
    if (accessToken) {
        revoke(accessToken);
        return;
    }
    [self requestAccessTokenWithRefreshToken:refreshToken completion:^(NSString *token) {
        if (token) {
            revoke(token);
        }
    }];
}

- (BOOL)isExpiredAccessTokenStatus:(NSInteger)status body:(NSDictionary *)body {
    return VibeDropboxIsExpiredAccessToken(status, body);
}

- (NSString *)errorSummaryForStatus:(NSInteger)status body:(NSDictionary *)body {
    return VibeDropboxErrorSummary(status, body);
}

// files/download by the target path or id.
- (NSMutableURLRequest *)transferRequestForTarget:(id)target accessToken:(NSString *)accessToken {
    return [self downloadRequestForPath:target token:accessToken];
}

// A download naming no file: refused at once, and what it buys is the
// connection to the content host, one per session, since a session's
// connections are its own (the download on one, its tail on the other).
- (void)warmUpConnectionsWithAccessToken:(NSString *)accessToken {
    NSMutableURLRequest *request = [self downloadRequestForPath:@"" token:accessToken];
    [[self.downloadSession dataTaskWithRequest:request] resume];
    [[self.callSession dataTaskWithRequest:request] resume];
}

#pragma mark - Transfers

// The metadata a content response carries in its Dropbox-API-Result header.
- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response
                               state:(NSMutableDictionary<NSString *, id> *)state {
    return VibeAccountJSONObject([[response valueForHTTPHeaderField:@"Dropbox-API-Result"]
                                  dataUsingEncoding:NSUTF8StringEncoding]);
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    return VibeDropboxRevOf(metadata);
}

- (int64_t)sizeOfMetadata:(NSDictionary *)metadata {
    return VibeDropboxSizeOf(metadata);
}

- (NSString *)logName {
    return @"Dropbox";
}

@end
