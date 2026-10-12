//
//  DropboxClientInternal.h
//  Vibe (iOS)
//
//  What the tests and the debug channel reach past a real sign-in with.
//

#import "DropboxClient.h"
#import "HTTPTransferClientInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface DropboxClient ()

// Links the account as a completed sign-in would, without the web sheet; the
// access token is fetched on first use, as after a relaunch.
- (void)adoptRefreshToken:(NSString *)refreshToken accountID:(NSString *)accountID;
// The sign-in's own follow-up, declared for the tests: asks Dropbox for the
// account's name and ID and stamps them, if the account is still the one asked.
- (void)refreshAccountNameWithCompletion:(dispatch_block_t)completion;

// TRAP: useSessionConfiguration: and retryDelayScale come from the import of
// HTTPTransferClientInternal.h above. Never redeclare them here. A
// redeclaration that cannot see the base's gets an ivar of its own. It
// starts at 0, not 1, and every retry wait would read it.

@end

NS_ASSUME_NONNULL_END
