//
//  DropboxMirror+Shared.h
//  Vibe (iOS)
//
//  Vibe's one Dropbox mirror, made with what only Vibe knows: its app key,
//  its Keychain item, its index xattr, its directory, and the saved budget.
//

#import "DropboxMirror.h"

NS_ASSUME_NONNULL_BEGIN

// The saved download budget. The shared mirror starts from it
// (VibeDropboxDownloadBudgetIndex), and Settings writes it, then sets
// downloadBudget.
extern NSString *const VibeDropboxDownloadBudgetKey;

@interface DropboxMirror (Shared)

// The app's one mirror over the one client. A singleton because the remote
// fetch, installed at launch, must reach the same instance every screen does.
@property (class, nonatomic, readonly) DropboxMirror *shared;

@end

NS_ASSUME_NONNULL_END
