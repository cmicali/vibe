//
//  DropboxClient.h
//  Vibe (iOS)
//
//  The Dropbox account and the HTTP calls made as it: PKCE sign-in, the
//  refresh token in the Keychain, the access token in memory, and a JSON call
//  and a download that refresh an expired token and retry a throttled request
//  on their own. Knows nothing of files on disk; DropboxMirror does.
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>

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
};

// Posted on main when the account is linked, unlinked or renamed.
extern NSNotificationName const VibeDropboxAccountDidChangeNotification;

@interface DropboxClient : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// keychainService nil keeps the account in memory only (the tests).
- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(nullable NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, getter=isLinked) BOOL linked;
// Dropbox's stable id; names the account's mirror directory.
@property (nonatomic, readonly, copy, nullable) NSString *accountID;
@property (nonatomic, readonly, copy, nullable) NSString *accountName;

// Main thread; completion on main. Presents Dropbox's sign-in page over the
// anchor, exchanges the code and reads the account.
- (void)signInWithPresentationAnchor:(ASPresentationAnchor)anchor
                          completion:(void (^)(NSError *_Nullable error))completion;

// Forgets the account at once and revokes the token in the background.
- (void)signOut;

// An RPC endpoint ("files/list_folder") with a JSON body, nil for an endpoint
// that takes none; the result is the decoded JSON object.
- (void)callEndpoint:(NSString *)endpoint
           arguments:(nullable NSDictionary *)arguments
          completion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

// files/download, streamed into destination as the bytes arrive, so its
// size on disk is the transfer's progress. The completion carries the file's
// metadata (the Dropbox-API-Result header); on failure destination is gone.
// The returned block cancels, any thread, at any point: before the request
// starts it never starts.
- (dispatch_block_t)downloadPath:(NSString *)path
                           toURL:(NSURL *)destination
                      completion:(void (^)(NSDictionary *_Nullable metadata, NSError *_Nullable error))completion;

// `length` bytes of files/download from `offset`, through a Range header:
// how a tag parse reads a file it does not download. Fewer bytes come back
// only at the file's end. The returned block cancels, as the download's does.
- (dispatch_block_t)readPath:(NSString *)path
                      offset:(uint64_t)offset
                      length:(uint64_t)length
                  completion:(void (^)(NSData *_Nullable data, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
