//
//  SettingsWindowController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;
@class SettingsAppearanceViewController;
@class SettingsGeneralViewController;

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindowController : NSWindowController

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// audioPane answers nil unless that pane is on screen, so outside refreshes
// cost nothing for a closed window; the pane catches up when it appears.
- (nullable SettingsAppearanceViewController *)appearancePane;
- (nullable SettingsGeneralViewController *)audioPane;

- (void)refreshSelectedPane;

// Selects the Appearance pane and opens the active theme's editor. The window
// must already be shown.
- (void)showThemeEditor;

// The window refuses engine-driven size changes (SettingsWindow), so every
// programmatic resize must come through here.
- (void)applyWindowFrame:(NSRect)frame;

// The same funnel in content points, top-anchored.
- (void)applyContentSize:(NSSize)size;

// Re-reads the Appearance pane's navigation and history state into the
// toolbar. Called on every page swap and pane switch.
- (void)updateThemeNavigation;

@end

NS_ASSUME_NONNULL_END
