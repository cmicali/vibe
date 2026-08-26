//
//  SettingsAppearanceViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsAppearanceViewController : SettingsPaneViewController

// Pushes the theme editor page for the active theme — the System
// Settings-style sub-page this pane swaps to in place. View > Theme > Edit
// Themes… lands here through SettingsWindowController.showThemeEditor.
- (void)showThemeEditorForActiveTheme;

@end
