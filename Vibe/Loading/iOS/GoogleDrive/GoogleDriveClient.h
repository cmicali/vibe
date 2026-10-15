//
//  GoogleDriveClient.h
//  Vibe (iOS)
//
//  The Google Drive account and the HTTP calls made as it. The account —
//  PKCE sign-in, the refresh token in the Keychain, the access token in
//  memory, and the failure ladder — is OAuthAccountClient's. This class
//  names Drive's endpoints and reads its answers: the GET call, the media
//  request, and the lookup before each media request that names the file's
//  version. Knows nothing of files on disk; GoogleDriveMirror does.
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>

#import "OAuthAccountClient.h"

NS_ASSUME_NONNULL_BEGIN

// The app's Keychain service for the refresh token.
extern NSString *const VibeGoogleDriveKeychainService;
// The Info.plist key that holds the iOS OAuth client id. Empty in a build
// that ships no Google Drive.
extern NSString *const VibeGoogleDriveClientIDInfoKey;

@interface GoogleDriveClient : OAuthAccountClient

// A GET of an API path ("files", "about", "files/<id>") with its query; the
// result is the decoded JSON object.
- (void)getPath:(NSString *)path
          query:(NSDictionary<NSString *, NSString *> *)query
     completion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

// The download and the ranged read are HTTPTransferClient's downloadTarget:…
// and readTarget:…, with a Drive file id as the target. Before each request
// the client looks the file up. Their metadata is {size, version,
// modifiedTime}: the answer's size, and the lookup's md5Checksum and date.
// The version is absent when the lookup's size is not the answer's, so
// those bytes are never resumed or joined to a tail.
//
// TRAP: the version is the lookup's, never the answer's. A media response
// states none. A file changed between a lookup and its request is labelled
// with the old version, and nothing catches that.

@end

NS_ASSUME_NONNULL_END
