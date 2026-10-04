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
- (nullable SettingsAppearanceViewController *)themesPane;
- (nullable SettingsGeneralViewController *)audioPane;

- (void)refreshSelectedPane;

// Selects the Themes pane and opens the active theme's editor. The window
// must already be shown.
- (void)showThemeEditor;

// The window refuses engine-driven size changes (SettingsWindow), so every
// programmatic resize must come through here.
- (void)applyWindowFrame:(NSRect)frame;

// The same funnel in content points, top-anchored.
- (void)applyContentSize:(NSSize)size;

// Records the location in the back/forward history and re-reads the
// Themes pane's state into the toolbar. Called on every page swap and
// pane switch.
- (void)updateNavigation;

// The toolbar's back/forward pill, across panes and the theme editor.
- (BOOL)canNavigateForward:(BOOL)forward;
- (void)navigateForward:(BOOL)forward;

// Edit > Undo's target while the window is key: the theme history on
// Appearance, the selected pane's own undo stack elsewhere.
- (IBAction)undo:(nullable id)sender;

// Types query into the sidebar's search field, as a user would; answers the
// identifiers of the panes left in the sidebar.
- (NSArray<NSString *> *)searchSettingsFor:(NSString *)query;

@end

NS_ASSUME_NONNULL_END
