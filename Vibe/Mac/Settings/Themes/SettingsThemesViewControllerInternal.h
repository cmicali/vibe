//
//  SettingsThemesViewControllerInternal.h
//  Vibe
//
//  Shared only between SettingsThemesViewController.m and its Editor and
//  EditorActions categories: the editor page's outlets, the list-side methods
//  it calls, and the editor's state and actions.
//

#import "SettingsThemesViewController.h"
#import "AppTheme.h"
#import "MainPlayerController+Settings.h"

NS_ASSUME_NONNULL_BEGIN

// Both pages' popups; a cap, not a size.
static const CGFloat kAppearancePopUpWidth = 220;

// A color well's binding to one side of its theme pair; see wellForDark:base:effect:.
static NSString *const kWellBase = @"base";
static NSString *const kWellEffect = @"effect";
static NSString *const kWellDark = @"dark";

// Not a symbol-name shape, so it can never reach a glyph field.
static NSString *const kGlyphChoiceCustomImage = @"custom-image";

// The other choice is SETTINGS_VALUE_WINDOW_TINT_CUSTOM, every Custom item's.
static NSString *const kChoiceStandard = @"standard";

@interface SettingsThemesViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    NSView *_detailContainer;
    NSStackView *_editorStack;
    SettingsSectionView *_transportSection;
    NSTextField *_nameField;
    // The theme the name field was populated for. The active theme can change
    // while the field editor is open (View > Theme), and a commit must not
    // rename the new one with the old one's half-typed text.
    NSString *_nameFieldThemeIdentifier;
    SettingsRowView *_nameRow;
    NSPopUpButton *_backgroundPopUp;
    SettingsRowView *_backgroundColorsRow;
    NSPopUpButton *_windowTintPopUp;
    SettingsRowView *_windowTintDarkRow, *_windowTintLightRow;
    NSPopUpButton *_defaultArtworkPopUp;
    SettingsRowView *_defaultArtworkImageRow, *_defaultArtworkDarkRow, *_defaultArtworkLightRow;
    NSSlider *_cornerRadiusSlider; // a VibeDetentSlider
    NSTextField *_cornerRadiusValue;
    VibeSwitch *_transportButtonsSwitch;
    VibeSwitch *_waveformGradientSwitch, *_waveformPlayheadSwitch, *_waveformCenteredSwitch;
    VibeSwitch *_waveformShadeOverlapsSwitch;
    NSPopUpButton *_modePopUp;
    VibeSwitch *_appIconShapeSwitch;
    NSPopUpButton *_cornerRadiusPopUp;
    NSStackView *_cornerRadiusCluster;
    NSPopUpButton *_buttonGradientPopUp;
    // The image fields' preview clusters by field key (kVibeThemeImage*).
    NSMutableDictionary<NSString *, NSButton *> *_imagePreviews;
    NSMutableDictionary<NSString *, NSButton *> *_imageClearBadges;
    NSMutableDictionary<NSString *, NSImageView *> *_imageMissingBadges;
    // The token of each slot's newest pick still reading its file. A later
    // pick, a clear or a glyph for the slot replaces or drops it.
    NSMutableDictionary<NSString *, id> *_imagePickTokens;
    // The transport buttons' rows by the button's dark image key.
    NSMutableDictionary<NSString *, NSPopUpButton *> *_glyphPopUps;
    NSMutableDictionary<NSString *, SettingsRowView *> *_buttonColorRows;
    NSMutableDictionary<NSString *, NSArray<SettingsRowView *> *> *_buttonImageRows;
    // The playlist's switched text colors, columns and rows, by pair base.
    NSMutableDictionary<NSString *, NSPopUpButton *> *_playlistColorPopUps;
    NSMutableDictionary<NSString *, NSStackView *> *_playlistColorPairs;
    // Every Dark/Light well pair, for Single Mode's collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    // Every themed color well → its pair's base key, side and effect.
    NSMapTable<NSColorWell *, NSDictionary *> *_wellBindings;
    NSMapTable<VibeSwitch *, void (^)(AppTheme *, BOOL)> *_themeSwitchWrites;
    NSPopUpButton *_waveformPopUp;
    NSPopUpButton *_waveformTypePopUp;
    SettingsRowView *_waveformTypeRow;
    NSSlider *_waveformBarDensitySlider;
    NSTextField *_waveformBarDensityValue;
    NSSlider *_waveformBarWidthSlider;
    NSTextField *_waveformBarWidthValue;
    NSPopUpButton *_waveformThemePopUp;
    SettingsRowView *_waveformThemeRow, *_customDarkRow, *_customLightRow;
    NSPopUpButton *_spectrumPalettePopUp;
    SettingsRowView *_spectrumPaletteRow;
    SettingsRowView *_bandsDarkRow, *_bandsLightRow, *_shadeOverlapsRow;
    SettingsRowView *_playheadColorsRow;
    NSPopUpButton *_playlistBackgroundPopUp;
    SettingsRowView *_playlistBackgroundColorsRow;
    NSPopUpButton *_playlistTintPopUp;
    SettingsRowView *_playlistTintDarkRow, *_playlistTintLightRow;
    NSPopUpButton *_volumeBarPopUp, *_volumeKnobPopUp, *_volumeLocationPopUp, *_volumeVisibilityPopUp;
    VibeSwitch *_volumeLabelsSwitch;
    SettingsRowView *_volumeBarDarkRow, *_volumeBarLightRow;
    SettingsRowView *_volumeKnobDarkRow, *_volumeKnobLightRow;
    NSTextField *_titleFontValue, *_artistFontValue, *_infoFontValue, *_playlistFontValue;
    NSTextField *_playlistDurationFontValue;
    // None while the panel is not editing a slot; changeFont: no-ops then.
    VibeFontSlot _fontEditingSlot;
}

#pragma mark - Implemented in SettingsThemesViewController.m

// The page swap, and the window title. The layout resolver ends with it.
- (void)applyEditorVisibility;

// Theme: <name> on the editor (the Name field's live text while editing),
// Themes otherwise.
- (void)applyEditorTitle;

// Every themed row funnels here after writing its currentTheme field.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect;
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect continuous:(BOOL)continuous;

// One style popup per page, twins sharing an action. selectWaveformStyle:in:
// shows an identifier under its style's entry, resolved as the views resolve it.
- (NSPopUpButton *)waveformStylePopUpButton;
- (NSImageView *)waveformPreviewView;
- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp;

// Copies the active working record, built-in changes included, and edits it.
- (IBAction)duplicateTheme:(nullable id)sender;

// The editor's first edit of a built-in copies it into a new active theme.
// Answers whether it did; every edit path runs it before persisting.
- (BOOL)forkBuiltInForEdit;

@end

#pragma mark - Implemented in SettingsThemesViewController+EditorActions.m

@interface SettingsThemesViewController (EditorActions) <NSFontChanging, NSTextFieldDelegate>

- (void)refreshEditorFromSettings;

// Closes the font panel and deactivates every color well.
- (void)closeEditorPanels;

// resolveLayoutStateFromSettings is implemented here too: every conditional
// row is the editor's. It ends in applyEditorVisibility.

// The rows' targets, which the builders in +Editor.m name.
- (void)themeModeChanged:(id)sender;
- (void)colorWellChanged:(NSColorWell *)sender;
- (void)backgroundStyleChanged:(id)sender;
- (void)windowTintChanged:(id)sender;
- (void)defaultArtworkChanged:(id)sender;
- (void)cornerRadiusModeChanged:(NSPopUpButton *)sender;
- (void)cornerRadiusChanged:(id)sender;
- (void)clearCustomImage:(NSButton *)sender;
- (void)chooseImage:(NSButton *)sender;
- (void)buttonGlyphChanged:(NSPopUpButton *)sender;
- (void)buttonGradientChanged:(id)sender;
- (void)volumeBarChanged:(id)sender;
- (void)volumeKnobChanged:(id)sender;
- (void)volumeLocationChanged:(id)sender;
- (void)volumeVisibilityChanged:(id)sender;
- (void)waveformBarSizingChanged:(NSSlider *)sender;
- (void)waveformTypeChanged:(id)sender;
- (void)waveformThemeChanged:(id)sender;
- (void)spectrumPaletteChanged:(id)sender;
- (void)playlistColorModeChanged:(NSPopUpButton *)sender;
- (void)playlistBackgroundStyleChanged:(id)sender;
- (void)playlistTintChanged:(id)sender;
- (void)selectFont:(NSButton *)sender;

@end

NS_ASSUME_NONNULL_END
