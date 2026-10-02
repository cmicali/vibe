//
//  DropboxClient.h
//  Vibe (iOS)
//
//  The Dropbox account and the HTTP calls made as it: PKCE sign-in, the
//  refresh token in the Keychain, the access token in memory, and a JSON call
//  and a download that refresh an expired token and retry a throttled request
//  on their own, the download resuming a dropped connection too. Knows nothing
//  of files on disk; DropboxMirror does.
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

// files/download, streamed into destination as the bytes arrive, so its
// size on disk is the transfer's progress. Made once, at the first response:
// a resend (a refreshed token, a throttle, a dropped connection) continues it
// with a Range header rather than starting over, and only for the same rev.
// The completion carries the first response's metadata (the
// Dropbox-API-Result header); on failure destination is gone. A file whose
// length differs from that metadata's size fails, and one dropped after its
// last byte is complete.
// progress, on the download's serial delivery queue and never after the
// completion, is called with 0 once the file is made, then after each write
// with the bytes on disk; size is the metadata's, -1 when it names none.
// The returned block cancels, any thread, at any point: before the request
// starts it never starts.
- (dispatch_block_t)downloadPath:(NSString *)path
                           toURL:(NSURL *)destination
                        progress:(nullable void (^)(uint64_t bytesWritten, int64_t size))progress
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
