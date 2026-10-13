//
//  AppDelegate.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;
@class SettingsWindowController;
@class SPUStandardUpdaterController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainPlayerController *mainPlayerController;
// nil until Settings is first shown.
@property (nonatomic, readonly) SettingsWindowController *settingsWindowController;

- (IBAction)openDocument:(id)sender;
// File > Add to Playlist…: Open's panel, appending what it opens.
- (IBAction)addToPlaylist:(id)sender;
// File > Open URL…: asks for a link in a small window of its own.
- (IBAction)openLink:(id)sender;
- (IBAction)showAboutWindow:(id)sender;
- (IBAction)showSettingsWindow:(id)sender;
// View > Theme > Edit Themes…: opens Settings on the theme editor.
- (IBAction)showThemeSettings:(id)sender;
- (IBAction)showSupportPage:(id)sender;
#if VIBE_DIRECT_DISTRIBUTION
// The target of Vibe > Check for Updates…, which validates it. nil in a Debug
// build launched without --update-feed. The rest of the updater is
// AppDelegate+Updates.
@property (nonatomic, readonly) SPUStandardUpdaterController *updaterController;
#endif

// The target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;

// A deliberate open like ⌘O and Open Recent, so it ends a Launch Services
// burst rather than joining it, but with its own append decision. Past that
// it is the one open funnel. urls may hold web links and .webloc files
// (LinkDropRules.h). Each opens its resolved link, in drop order.
- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

// Escape on the player window. Every open still resolving its links stops,
// and opens nothing. NO when none was.
- (BOOL)cancelLinkOpens;

// Open URL: a drop's road with the one typed link. Its file opens as a
// replace. The request is taken at the call. A later replacing open
// supersedes and cancels it. A link that fails or is cancelled leaves
// the playlist as it is. A failure that is still current then shows in the
// header. Completion on main, with exactly one of file and error. The
// returned block cancels, on main.
- (dispatch_block_t)openLinkString:(NSString *)string
                        completion:(void (^)(NSURL *file, NSError *error))completion;

// Re-levels the About, Settings, and Open URL windows to alwaysOnTop: at
// normal level the floating player would bury them.
- (void)applyAuxiliaryWindowLevels;

@end
