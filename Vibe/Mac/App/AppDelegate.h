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
- (IBAction)showAboutWindow:(id)sender;
- (IBAction)showSettingsWindow:(id)sender;
// View > Theme > Edit Themes…: opens Settings on the theme editor.
- (IBAction)showThemeSettings:(id)sender;
- (IBAction)showSupportPage:(id)sender;
#if VIBE_DIRECT_DISTRIBUTION
// The target of Vibe > Check for Updates…, which validates it. nil in a Debug
// build launched without --update-feed.
@property (nonatomic, readonly) SPUStandardUpdaterController *updaterController;
// Settings > General's check frequency in seconds, 0 for never. Sparkle
// stores it. Reads 0 and ignores writes while no updater runs: a Debug build
// launched without --update-feed.
@property (nonatomic) NSTimeInterval updateCheckInterval;
#endif

// The target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;

// A deliberate open like ⌘O and Open Recent, so it ends a Launch Services
// burst rather than joining it, but with its own append decision. Past that
// it is the one open funnel.
- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

// Re-levels the About and Settings windows to alwaysOnTop: at normal level
// the floating player would bury them, Settings included.
- (void)applyAuxiliaryWindowLevels;

@end
