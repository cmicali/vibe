//
//  SettingsAppearanceViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsAppearanceViewController : SettingsPaneViewController

// A built-in is first copied, including its unsaved waveform changes.
- (void)showThemeEditorForActiveTheme;

// The toolbar navigation pill's model: back pops the editor; forward, armed
// by a pop, re-opens it.
@property (readonly, nonatomic) BOOL canGoBack;
@property (readonly, nonatomic) BOOL canGoForward;
- (void)navigateBack;
- (void)navigateForward;

// A TEMPORARY preview of the main window, written to the transient preview
// style, never the stored setting; viewDidDisappear drops it.
- (void)previewAppearanceDark:(BOOL)dark;

// The toolbar's dice: each rolls the active theme and applies it whole. Only
// on the editor page over a user theme.
@property (readonly, nonatomic) BOOL canRandomize;
- (void)randomizeThemeSettings;
- (void)randomizeThemeColors;
// The store's theme history, for the toolbar arrows and Edit > Undo/Redo on
// both pages. A restore applies the theme whole.
- (BOOL)canRestoreThemeHistoryForward:(BOOL)forward;
- (void)restoreThemeHistoryForward:(BOOL)forward;

@end
