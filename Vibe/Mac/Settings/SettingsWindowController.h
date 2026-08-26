//
//  SettingsWindowController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

@interface SettingsWindowController : NSWindowController

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Selects the Appearance pane and lands on the theme editor — View > Theme >
// Edit Themes…'s destination. The window must already be shown (the app
// delegate's showThemeSettings: does both).
- (void)showThemeEditor;

// The settings window refuses engine-driven size changes (the constraint
// engine's fitting snap; see SettingsWindow in the implementation), so every
// deliberate programmatic resize funnels through here to be told apart.
- (void)applyWindowFrame:(NSRect)frame;

// Re-reads the Appearance pane's back/forward state into the toolbar's
// navigation control. The pane calls it on every page swap, the tab
// controller on every pane switch.
- (void)updateThemeNavigation;

@end
