//
//  SettingsWindowController.h
//  Vibe
//
//  Vibe's settings window: the nine panes over the player, and the Themes
//  pane's toolbar items (the dice, the theme history and the appearance
//  preview). The window itself is SettingsPanesWindowController.
//

#import "SettingsPanesWindowController.h"

@class MainPlayerController;
@class SettingsThemesViewController;
@class SettingsAudioOutputViewController;

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindowController : SettingsPanesWindowController

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// audioPane answers nil unless that pane is on screen, so outside refreshes
// cost nothing for a closed window; the pane catches up when it appears.
- (nullable SettingsThemesViewController *)themesPane;
- (nullable SettingsAudioOutputViewController *)audioPane;

// Selects the Themes pane and opens the active theme's editor. The window
// must already be shown.
- (void)showThemeEditor;

@end

NS_ASSUME_NONNULL_END
