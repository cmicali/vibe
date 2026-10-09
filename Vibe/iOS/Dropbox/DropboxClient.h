//
//  DropboxClient.h
//  Vibe (iOS)
//
//  The Dropbox account and the HTTP calls made as it: PKCE sign-in, the
//  refresh token in the Keychain, the access token in memory, and a JSON call
//  and a download that refresh an expired token and retry a throttled request
//  on their own. The download and the ranged read are HTTPTransferClient's,
//  which resumes a dropped connection too; this class makes their requests
//  and reads Dropbox's answers. Knows nothing of files on disk; DropboxMirror
//  does.
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>

#import "HTTPTransferClient.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const VibeDropboxErrorDomain;

typedef NS_ERROR_ENUM(VibeDropboxErrorDomain, VibeDropboxError) {
    // No account, or Dropbox no longer honors the one there was.
    VibeDropboxErrorNotLinked = 1,
    // The sign-in did not produce an account; cancelled included.
    VibeDropboxErrorSignInFailed,
    // A call Dropbox answered with an error; the summary is the description.
    VibeDropboxErrorAPI,
    VibeDropboxErrorCancelled,
    // A download's resend answered another version (rev) than its first
    // response: the bytes written cannot be trusted, and are deleted.
    VibeDropboxErrorFileChanged,
};

// The one spelling of a Dropbox error, the client's and the mirror's.
static inline NSError *VibeDropboxMakeError(VibeDropboxError code, NSString *description) {
    return [NSError errorWithDomain:VibeDropboxErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Posted on main when the account is linked, unlinked or renamed.
extern NSNotificationName const VibeDropboxAccountDidChangeNotification;

@interface DropboxClient : HTTPTransferClient

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration NS_UNAVAILABLE;

// keychainService nil keeps the account in memory only (the tests).
- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(nullable NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, getter=isLinked) BOOL linked;
// Dropbox's stable id; names the account's mirror directory.
@property (nonatomic, readonly, copy, nullable) NSString *accountID;
@property (nonatomic, readonly, copy, nullable) NSString *accountName;

// Main thread; completion on main. Presents Dropbox's sign-in page over the
// anchor, exchanges the code and reads the account. Closing the sheet
// completes with no error: it is the user's answer, not a failure to report.
- (void)signInWithPresentationAnchor:(ASPresentationAnchor)anchor
                          completion:(void (^)(NSError *_Nullable error))completion;

// Forgets the account at once and revokes the token in the background.
- (void)signOut;

// An RPC endpoint ("files/list_folder") with a JSON body, nil for an endpoint
// that takes none; the result is the decoded JSON object.
- (void)callEndpoint:(NSString *)endpoint
           arguments:(nullable NSDictionary *)arguments
          completion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

// The download and the ranged read are HTTPTransferClient's downloadTarget:…
// and readTarget:…, with a Dropbox path as the target. Their metadata is the
// response's Dropbox-API-Result, nil when it carries none.

// Once per launch, off main, and only with an account: refreshes the access
// token and opens both sessions' connections to the content host, so the
// first play pays neither the refresh nor the TLS handshakes. Later calls do
// nothing.
- (void)warmUp;

@end

NS_ASSUME_NONNULL_END
