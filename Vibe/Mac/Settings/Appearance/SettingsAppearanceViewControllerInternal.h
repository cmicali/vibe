//
//  SettingsAppearanceViewControllerInternal.h
//  Vibe
//
//  Shared only between SettingsAppearanceViewController.m and its Editor
//  category: the editor page's outlets and the list-side methods it calls.
//

#import "SettingsAppearanceViewController.h"
#import "AppTheme.h"
#import "MainPlayerController+Settings.h"

NS_ASSUME_NONNULL_BEGIN

// Both pages' popups; a cap, not a size.
static const CGFloat kAppearancePopUpWidth = 220;

// Ticks above and below the track at detentValue, where its action snaps.
// NSSlider's own tick marks are evenly spaced and single-sided.
@interface VibeDetentSlider : NSSlider
@property (nonatomic) double detentValue;
@end

@interface SettingsAppearanceViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    NSView *_detailContainer;
    NSButton *_duplicateButton;
    SettingsRowView *_builtInRow;
    NSStackView *_editorStack;
    SettingsSectionView *_transportSection, *_timeSection;
    SettingsRowView *_infoFontRow;
    NSArray<SettingsRowView *> *_fileInfoRows;
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
    NSSlider *_cornerRadiusSlider; // a VibeDetentSlider
    NSTextField *_cornerRadiusValue;
    NSSwitch *_fileInfoSwitch;
    NSSwitch *_transportButtonsSwitch, *_statusIconsSwitch, *_timeLabelsSwitch;
    NSButton *_timeTotalRadio, *_timeRemainingRadio;
    NSSwitch *_showBPMSwitch, *_showKeySwitch;
    NSPopUpButton *_keyNotationPopUp;
    NSSwitch *_keyColorsSwitch;
    NSSwitch *_waveformGradientSwitch;
    NSSwitch *_playlistNumberSwitch, *_playlistArtworkSwitch;
    NSPopUpButton *_modePopUp;
    NSPopUpButton *_dockIconPopUp;
    NSSwitch *_appIconShapeSwitch;
    NSSwitch *_customCornerRadiusSwitch;
    NSPopUpButton *_buttonGradientPopUp;
    // The image fields' preview clusters by field key (kVibeThemeImage*).
    NSMutableDictionary<NSString *, NSButton *> *_imagePreviews;
    NSMutableDictionary<NSString *, NSButton *> *_imageClearBadges;
    NSMutableDictionary<NSString *, NSImageView *> *_imageMissingBadges;
    // The transport buttons' rows by the button's dark image key.
    NSMutableDictionary<NSString *, NSPopUpButton *> *_glyphPopUps;
    NSMutableDictionary<NSString *, SettingsRowView *> *_buttonColorRows;
    NSMutableDictionary<NSString *, NSArray<SettingsRowView *> *> *_buttonImageRows;
    NSSwitch *_playlistDurationSwitch;
    // The playlist columns' text colors by pair base.
    NSMutableDictionary<NSString *, NSSwitch *> *_playlistColorSwitches;
    NSMutableDictionary<NSString *, SettingsRowView *> *_playlistColorRows;
    // Every Dark/Light well pair, for Single Mode's collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    // Every themed color well → its pair's base key, side and effect.
    NSMapTable<NSColorWell *, NSDictionary *> *_wellBindings;
    NSMapTable<NSSwitch *, void (^)(AppTheme *, BOOL)> *_themeSwitchWrites;
    NSPopUpButton *_waveformPopUp;
    NSSlider *_waveformBarDensitySlider;
    NSTextField *_waveformBarDensityValue;
    NSSlider *_waveformBarWidthSlider;
    NSTextField *_waveformBarWidthValue;
    NSPopUpButton *_waveformThemePopUp;
    SettingsRowView *_customDarkRow, *_customLightRow;
    NSPopUpButton *_playlistBackgroundPopUp;
    SettingsRowView *_playlistBackgroundColorsRow;
    NSPopUpButton *_playlistTintPopUp;
    SettingsRowView *_playlistTintDarkRow, *_playlistTintLightRow;
    NSPopUpButton *_volumeBarPopUp, *_volumeKnobPopUp, *_volumeLocationPopUp;
    NSSwitch *_volumeLabelsSwitch;
    SettingsRowView *_volumeBarDarkRow, *_volumeBarLightRow;
    SettingsRowView *_volumeKnobDarkRow, *_volumeKnobLightRow;
    NSTextField *_titleFontValue, *_artistFontValue, *_infoFontValue, *_playlistFontValue;
    NSTextField *_playlistDurationFontValue;
    // None while the panel is not editing a slot; changeFont: no-ops then.
    VibeFontSlot _fontEditingSlot;
}

#pragma mark - Implemented in SettingsAppearanceViewController.m

// The page swap, and the window title. The layout resolver ends with it.
- (void)applyEditorVisibility;

// Theme: <name> on the editor (the Name field's live text while editing),
// Appearance otherwise.
- (void)applyEditorTitle;

// Every themed row funnels here after writing its currentTheme field.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect;
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect continuous:(BOOL)continuous;

// One style popup per page, twins sharing an action. selectWaveformStyle:in:
// shows the default style for an unknown identifier, the view's own fallback.
- (NSPopUpButton *)waveformStylePopUpButton;
- (NSImageView *)waveformPreviewView;
- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp;

// Copies the active working record, built-in changes included, and edits it.
- (IBAction)duplicateTheme:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
