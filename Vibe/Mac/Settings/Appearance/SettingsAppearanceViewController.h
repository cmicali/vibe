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

// The toolbar navigation control's model: back pops the editor to the theme
// list; forward, armed by a pop, re-opens the editor. The window controller
// reads the two flags for the control's enablement whenever the pane
// re-resolves its pages.
@property (readonly, nonatomic) BOOL canGoBack;
@property (readonly, nonatomic) BOOL canGoForward;
- (void)navigateBack;
- (void)navigateForward;

// The titlebar toggle's model, and outside the pane for the same reason the
// two above are: a TEMPORARY light/dark preview of the main window, written to
// the transient preview style rather than to the stored setting, so a visit
// leaves the app looking the way it found it. viewDidDisappear drops it, which
// makes leaving the pane and closing the window one revert.
- (void)previewAppearanceDark:(BOOL)dark;

// The toolbar's two dice, outside the pane for the same reason: each rolls
// the active theme (AppTheme's randomizeSettingsWithWaveformStyles: and
// randomizeColors) and applies the whole result. Only on the editor page
// over a user theme — a built-in cannot be edited — which canRandomize
// reports for the control's enablement.
@property (readonly, nonatomic) BOOL canRandomize;
- (void)randomizeThemeSettings;
- (void)randomizeThemeColors;
// The third segment: puts the theme back the way it was before the last
// edit — any edit on the editor page, a roll included, drags coalesced —
// most recent first, for as long as the edited theme stays active.
@property (readonly, nonatomic) BOOL canUndoEdit;
- (void)undoEdit;

@end
