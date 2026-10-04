//
//  SettingsAppearanceViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsAppearanceViewController : SettingsPaneViewController

// The editor page, over the active theme. A built-in opens as it is and is
// copied into a new theme by its first edit. The window's history drives it.
@property (readonly, nonatomic) BOOL editorShown;
- (void)setEditorShown:(BOOL)shown;

// A TEMPORARY preview of the main window, written to the transient preview
// style, never the stored setting; viewDidDisappear drops it.
- (void)previewAppearanceDark:(BOOL)dark;

// The toolbar's dice: each rolls the active theme and applies it whole. Only
// on the editor page (editorShown); over a built-in, the roll is its first edit.
- (void)randomizeThemeSettings;
- (void)randomizeThemeColors;
// The store's theme history, for the toolbar arrows and Edit > Undo/Redo on
// both pages. A restore applies the theme whole.
- (BOOL)canRestoreThemeHistoryForward:(BOOL)forward;
- (void)restoreThemeHistoryForward:(BOOL)forward;

@end
