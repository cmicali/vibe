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

// Ages the access token out, so the next call refreshes it.
- (void)expireAccessToken;

@end

NS_ASSUME_NONNULL_END
