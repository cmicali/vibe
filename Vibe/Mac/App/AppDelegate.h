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
// File > Open URL…: asks for a link in a sheet on the player window.
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
// it is the one open funnel.
- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

// Open URL: the typed link resolved (LinkStore), then its file opened as a
// replace through the open funnel. The request is taken at the call. A
// later open supersedes it. A link that fails leaves the playlist as it is.
// Completion on main, with exactly one of file and error.
- (void)openLinkString:(NSString *)string
            completion:(void (^)(NSURL *file, NSError *error))completion;

// Re-levels the About and Settings windows to alwaysOnTop: at normal level
// the floating player would bury them, Settings included.
- (void)applyAuxiliaryWindowLevels;

@end
