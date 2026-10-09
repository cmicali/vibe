//
//  AppDelegate.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;
@class SettingsWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainPlayerController *mainPlayerController;
// nil until Settings is first shown.
@property (nonatomic, readonly) SettingsWindowController *settingsWindowController;

- (IBAction)openDocument:(id)sender;
// File > Open URL…: asks for a link in a small window of its own.
- (IBAction)openLink:(id)sender;
- (IBAction)showAboutWindow:(id)sender;
- (IBAction)showSettingsWindow:(id)sender;
// View > Theme > Edit Themes…: opens Settings on the theme editor.
- (IBAction)showThemeSettings:(id)sender;
- (IBAction)showSupportPage:(id)sender;

// The target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;

// A deliberate open like ⌘O and Open Recent, so it ends a Launch Services
// burst rather than joining it, but with its own append decision. Past that
// it is the one open funnel. urls may hold web links and .webloc files
// (LinkRules.h). Each opens its resolved link, in drop order.
- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

// Escape on the player window. Every drop still resolving its links stops,
// and opens nothing. NO when none was.
- (BOOL)cancelLinkOpens;

// Open URL: the typed link resolved (LinkStore), then its file opened as a
// replace through the open funnel. The request is taken at the call. A
// later open supersedes it. A link that fails or is cancelled leaves the
// playlist as it is. A failure that is still current then shows in the
// header. Completion on main, with exactly one of file and error. The
// returned block cancels the resolve on main, as LinkStore's does.
- (dispatch_block_t)openLinkString:(NSString *)string
                        completion:(void (^)(NSURL *file, NSError *error))completion;

// Re-levels the About, Settings, and Open URL windows to alwaysOnTop: at
// normal level the floating player would bury them.
- (void)applyAuxiliaryWindowLevels;

@end
