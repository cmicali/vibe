//
//  DropboxClientInternal.h
//  Vibe (iOS)
//
//  What the tests and the debug channel reach past a real sign-in with.
//

#import "DropboxClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface DropboxClient ()

// Links the account as a completed sign-in would, without the web sheet; the
// access token is fetched on first use, as after a relaunch.
- (void)adoptRefreshToken:(NSString *)refreshToken accountID:(NSString *)accountID;

// Rebuilds both sessions over `configuration` — nil for the one the client
// was made with — finishing what is in flight on the old ones: how the debug
// channel puts a fake Dropbox under the client and takes it away again.
- (void)useSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;

@end

NS_ASSUME_NONNULL_END
