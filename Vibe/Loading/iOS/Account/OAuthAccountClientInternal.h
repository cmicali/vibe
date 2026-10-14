//
//  OAuthAccountClientInternal.h
//  Vibe (iOS)
//
//  The hooks a subclass overrides, the calls it makes, and what the tests and
//  the debug channel reach past a real sign-in with.
//

#import "OAuthAccountClient.h"
#import "HTTPTransferClientInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface OAuthAccountClient ()

#pragma mark Seams

// Links the account as a completed sign-in would, without the web sheet; the
// access token is fetched on first use, as after a relaunch.
- (void)adoptRefreshToken:(NSString *)refreshToken accountID:(NSString *)accountID;
// The sign-in's follow-up when its token answer named the account: asks for
// the account's name and id and stamps them, if the account is still the one
// asked.
- (void)refreshAccountNameWithCompletion:(dispatch_block_t)completion;

// TRAP: useSessionConfiguration: and retryDelayScale come from the import of
// HTTPTransferClientInternal.h above. Never redeclare them here. A
// redeclaration that cannot see the base's gets an ivar of its own. It
// starts at 0, not 1, and every retry wait would read it.

#pragma mark Calls a subclass makes

// An authorized call through the ladder. makeRequest builds each attempt's
// request with that attempt's access token. The result is the answer's JSON
// object, empty for an answer that holds none.
- (void)sendAuthorizedRequest:(NSMutableURLRequest *(^)(NSString *accessToken))makeRequest
                   completion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

// A form POST with no token, as a token or revocation endpoint takes it.
- (void)postForm:(NSDictionary<NSString *, NSString *> *)fields
           toURL:(NSURL *)url
      completion:(void (^)(NSDictionary *_Nullable body, NSInteger status, NSError *_Nullable error))completion;

// A fresh access token for a refresh token, outside the account: how a
// revocation that needs one gets it once the account is forgotten. Nil on
// any failure.
- (void)requestAccessTokenWithRefreshToken:(NSString *)refreshToken
                                completion:(void (^)(NSString *_Nullable accessToken))completion;

#pragma mark Hooks

// The service's sign-in page for one attempt.
- (NSURL *)authorizeURLWithCodeChallenge:(NSString *)codeChallenge state:(NSString *)state;
// The scheme ASWebAuthenticationSession watches for the redirect.
- (NSString *)callbackScheme;
// Sent to the sign-in page and again with the code; a service refuses a
// mismatch.
- (NSString *)redirectURI;
- (NSURL *)tokenURL;
// The account id a token answer names, nil when only the identity call names
// it. Such a sign-in reads the identity before it links the account, since
// the id names the mirror's directory.
- (nullable NSString *)accountIDOfTokenAnswer:(NSDictionary *)answer;
// The call that names the account, and what its answer says.
- (NSMutableURLRequest *)identityRequestWithAccessToken:(NSString *)accessToken;
- (nullable NSString *)accountIDOfIdentity:(NSDictionary *)identity;
- (nullable NSString *)nameOfIdentity:(NSDictionary *)identity;
// Ends the grant on the service's side, after the account is forgotten.
// accessToken is a fresh one, nil when the account held none.
- (void)revokeRefreshToken:(NSString *)refreshToken accessToken:(nullable NSString *)accessToken;
// A refused call whose access token only aged out: the ladder refreshes it
// once and resends. Any other 401 unlinks.
- (BOOL)isExpiredAccessTokenStatus:(NSInteger)status body:(nullable NSDictionary *)body;
// A refused call the service will take later: waited for and resent as a 429
// is. The default is NO.
- (BOOL)isThrottleStatus:(NSInteger)status body:(nullable NSDictionary *)body;
// The one line a failure leaves in the log and the error.
- (NSString *)errorSummaryForStatus:(NSInteger)status body:(nullable NSDictionary *)body;
// One transfer attempt's request, sent with accessToken. The base adds the
// Range. Exactly one of request and error.
- (void)makeRequestForTarget:(id)target
                 accessToken:(NSString *)accessToken
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *_Nullable request, NSError *_Nullable error))completion;
// The warm-up's own requests, once the access token is fresh.
- (void)warmUpConnectionsWithAccessToken:(NSString *)accessToken;

@end

NS_ASSUME_NONNULL_END
