//
//  OAuthAccountClient.h
//  Vibe (iOS)
//
//  One OAuth account and the HTTP calls made as it: PKCE sign-in in
//  ASWebAuthenticationSession, the refresh token in the Keychain, the access
//  token in memory, and one failure ladder every call and transfer shares.
//  The ladder refreshes an expired token once, unlinks on any other 401, and
//  waits and resends a throttled request. A subclass names the service's
//  endpoints and reads its answers through the hooks in
//  OAuthAccountClientInternal.h (DropboxClient, GoogleDriveClient). The
//  download and the ranged read are HTTPTransferClient's. Knows nothing of
//  files on disk; AccountMirror does.
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>

#import "HTTPTransferClient.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const VibeAccountErrorDomain;

typedef NS_ERROR_ENUM(VibeAccountErrorDomain, VibeAccountError) {
    // No account, or the service no longer honors the one there was.
    VibeAccountErrorNotLinked = 1,
    // Sign-in failed. Closing the sheet completes without an error.
    VibeAccountErrorSignInFailed,
    // A call the service answered with an error; its summary is the
    // description.
    VibeAccountErrorAPI,
    VibeAccountErrorCancelled,
    // A download's resend answered another version than its first response:
    // the bytes written cannot be trusted, and are deleted.
    VibeAccountErrorFileChanged,
};

// The one spelling of an account error, every client's and every mirror's.
static inline NSError *VibeAccountMakeError(VibeAccountError code, NSString *description) {
    return [NSError errorWithDomain:VibeAccountErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Posted on main, with the client as its object, when its account is linked,
// unlinked or renamed.
extern NSNotificationName const VibeAccountDidChangeNotification;

@interface OAuthAccountClient : HTTPTransferClient

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration NS_UNAVAILABLE;

// clientID is the service's id for the app. keychainService nil keeps the
// account in memory only (the tests).
- (instancetype)initWithClientID:(NSString *)clientID
                 keychainService:(nullable NSString *)keychainService
                   configuration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, copy) NSString *clientID;

@property (nonatomic, readonly, getter=isLinked) BOOL linked;
// The service's stable id for the account; names the account's mirror
// directory.
@property (nonatomic, readonly, copy, nullable) NSString *accountID;
@property (nonatomic, readonly, copy, nullable) NSString *accountName;

// Main thread; completion on main. Presents the service's sign-in page over
// the anchor, exchanges the code and reads the account. Closing the sheet
// completes with no error: it is the user's answer, not a failure to report.
- (void)signInWithPresentationAnchor:(ASPresentationAnchor)anchor
                          completion:(void (^)(NSError *_Nullable error))completion;

// Forgets the account at once and attempts remote revocation in the background.
- (void)signOut;

// Once per launch, off main, and only with an account: refreshes the access
// token and opens the connections the first play would, so it pays neither
// the refresh nor the TLS handshakes. Later calls do nothing.
- (void)warmUp;

@end

NS_ASSUME_NONNULL_END
