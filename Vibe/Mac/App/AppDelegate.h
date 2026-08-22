//
//  AppDelegate.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainPlayerController *mainPlayerController;

- (IBAction)openDocument:(id)sender;
- (IBAction)showAboutWindow:(id)sender;
- (IBAction)showSettingsWindow:(id)sender;

// The target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;

// The window's file drop, for a caller that already knows what it opened and
// whether it appends. It enters the coalescer through the same deliberate door
// as ⌘O and Open Recent, so it ends a Launch Services burst in progress rather
// than joining it, and carries its own append decision where those two always
// replace. Everything past that is the one funnel — the ordering token, the
// wait for a restoring grant, the auto-added bookmark, the expansion, the
// lifetime stats and the empty-result handling — so a drop cannot drift from
// a Finder open.
- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

// Re-levels the About and Settings windows to match
// AppSettings.sharedInstance.alwaysOnTop.
// They must ride at the player's level: left at normal level, the floating
// player would bury them — Settings being where the very checkbox that turns
// the mode off lives. MainPlayerController's applyAlwaysOnTop calls it on
// every change; the show methods apply it to a window created while the mode
// is already on.
- (void)applyAuxiliaryWindowLevels;

@end
