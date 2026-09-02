//
//  SettingsWindowController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;
@class SettingsAppearanceViewController;

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindowController : NSWindowController

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// The Appearance pane, the one pane other code addresses by name: the theme
// editor's host, and the debug channel's preview and navigation target.
- (nullable SettingsAppearanceViewController *)appearancePane;

// Selects the Appearance pane and lands on the theme editor — View > Theme >
// Edit Themes…'s destination. The window must already be shown (the app
// delegate's showThemeSettings: does both).
- (void)showThemeEditor;

// The settings window refuses engine-driven size changes (the constraint
// engine's fitting snap; see SettingsWindow in the implementation), so every
// deliberate programmatic resize funnels through here to be told apart.
- (void)applyWindowFrame:(NSRect)frame;

// The same funnel in content points, top-anchored — the titlebar stays put
// and the bottom edge moves, as a drag of the bottom edge would leave it. A
// size within half a point of the current one is left alone.
- (void)applyContentSize:(NSSize)size;

// Re-reads the Appearance pane's back/forward state into the toolbar's
// navigation control. The pane calls it on every page swap, the tab
// controller on every pane switch.
- (void)updateThemeNavigation;

@end

NS_ASSUME_NONNULL_END
