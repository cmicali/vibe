//
//  DropboxClient.h
//  Vibe (iOS)
//
//  The Dropbox account and the HTTP calls made as it. The account itself —
//  PKCE sign-in, the refresh token in the Keychain, the access token in
//  memory, and the failure ladder — is OAuthAccountClient's. This class
//  names Dropbox's endpoints and reads its answers: the RPC call, the
//  download by path or id, and the Dropbox-API-Result a content response
//  carries. Knows nothing of files on disk; DropboxMirror does.
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>

#import "OAuthAccountClient.h"

NS_ASSUME_NONNULL_BEGIN

// The app's Keychain service for the refresh token.
extern NSString *const VibeDropboxKeychainService;
// The Info.plist key that holds the app key.
extern NSString *const VibeDropboxAppKeyInfoKey;

@interface DropboxClient : OAuthAccountClient

- (instancetype)initWithClientID:(NSString *)clientID
                 keychainService:(nullable NSString *)keychainService
                   configuration:(NSURLSessionConfiguration *)configuration NS_UNAVAILABLE;

// The app key is Dropbox's client id. keychainService nil keeps the account
// in memory only (the tests).
- (instancetype)initWithAppKey:(NSString *)appKey
               keychainService:(nullable NSString *)keychainService
                 configuration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

// An RPC endpoint ("files/list_folder") with a JSON body, nil for an endpoint
// that takes none; the result is the decoded JSON object.
- (void)callEndpoint:(NSString *)endpoint
           arguments:(nullable NSDictionary *)arguments
          completion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

// The download and the ranged read are HTTPTransferClient's downloadTarget:…
// and readTarget:…, with a Dropbox path or id as the target, or a shared
// link's file as {url, path}. Their metadata is the response's
// Dropbox-API-Result, nil when it carries none.

@end

NS_ASSUME_NONNULL_END
