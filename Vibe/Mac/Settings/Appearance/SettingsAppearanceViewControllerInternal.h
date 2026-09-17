//
//  SettingsAppearanceViewControllerInternal.h
//  Vibe
//
//  The private surface shared between SettingsAppearanceViewController.m and
//  its Editor category: the class extension holding the editor page's outlets
//  — the state the category builds and refreshes and the class file only
//  shows and hides — and the list-side methods the editor calls. Do not use
//  it outside the Appearance pane's implementation files; everything else
//  goes through SettingsAppearanceViewController.h.
//

#import "SettingsAppearanceViewController.h"
#import "AppTheme.h"                      // VibeFontSlot, the font panel's target slot
#import "MainPlayerController+Settings.h" // VibeSettingsLiveEffect, the write funnel's argument

NS_ASSUME_NONNULL_BEGIN

// Both pages' popups: the list page's Appearance and Waveform rows and every
// dropdown of the editor. A cap for runaway titles, not a fixed size.
static const CGFloat kAppearancePopUpWidth = 220;

// A slider with a tick above and below the track at detentValue — the visual
// for its action's magnetic snap onto the default. NSSlider's own tick marks
// are evenly spaced and single-sided, so the pair is drawn by the class; the
// knob geometry mirrors AppKit's linear layout (half the knob inset at each
// end). Corner radius, waveform density and waveform gain share it; the
// implementation is the Editor category's.
@interface VibeDetentSlider : NSSlider
@property (nonatomic) double detentValue;
@end

// The table conformances stay on the class because
// SettingsAppearanceViewController.m implements them; the font panel's and the
// text field's are declared on the Editor category, which implements those.
//
// Only the state the category touches lives here; the list page's outlets
// stay private to SettingsAppearanceViewController.m.
@interface SettingsAppearanceViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    // The editor page.
    NSView *_detailContainer;
    NSButton *_duplicateButton;
    SettingsRowView *_builtInRow;
    NSStackView *_editorStack;
    SettingsSectionView *_transportSection, *_timeSection;
    SettingsRowView *_infoFontRow;
    NSArray<SettingsRowView *> *_fileInfoRows;
    NSTextField *_nameField;
    // The theme the name field's text was populated for. The rename commit
    // reads the ACTIVE identifier, and the active theme can change while the
    // field editor is open (View > Theme works while this window is key), so
    // without this capture a commit would rename whatever theme is now active
    // to the old one's half-typed text — the album-art sheet's stale-target
    // drop, for the field editor.
    NSString *_nameFieldThemeIdentifier;
    SettingsRowView *_nameRow;
    NSPopUpButton *_backgroundPopUp;
    SettingsRowView *_backgroundColorsRow;
    NSPopUpButton *_windowTintPopUp;
    SettingsRowView *_windowTintDarkRow, *_windowTintLightRow;
    NSSlider *_cornerRadiusSlider; // a VibeDetentSlider, typed by what the class file reads of it
    NSTextField *_cornerRadiusValue;
    NSSwitch *_fileInfoSwitch;
    NSSwitch *_transportButtonsSwitch, *_statusIconsSwitch, *_timeLabelsSwitch;
    NSButton *_timeTotalRadio, *_timeRemainingRadio;
    NSSwitch *_showBPMSwitch, *_showKeySwitch;
    NSPopUpButton *_keyNotationPopUp;
    NSSwitch *_keyColorsSwitch;
    NSSwitch *_waveformGradientSwitch;
    NSSwitch *_playlistArtworkSwitch;
    NSPopUpButton *_modePopUp;
    NSPopUpButton *_dockIconPopUp;
    NSSwitch *_appIconShapeSwitch;
    NSSwitch *_customCornerRadiusSwitch;
    NSPopUpButton *_buttonGradientPopUp;
    // The image fields' preview clusters by field key (kVibeThemeImage*): the
    // preview button, its hover-revealed clear badge and its missing badge.
    // One builder, one refresh loop and one hover handler serve all seven.
    NSMutableDictionary<NSString *, NSButton *> *_imagePreviews;
    NSMutableDictionary<NSString *, NSButton *> *_imageClearBadges;
    NSMutableDictionary<NSString *, NSImageView *> *_imageMissingBadges;
    // The transport buttons' rows by the button's dark image key: the glyph
    // popup, and the color row and image rows that swap on whether an image
    // is set (the play button has an image row per state).
    NSMutableDictionary<NSString *, NSPopUpButton *> *_glyphPopUps;
    NSMutableDictionary<NSString *, SettingsRowView *> *_buttonColorRows;
    NSMutableDictionary<NSString *, NSArray<SettingsRowView *> *> *_buttonImageRows;
    NSSwitch *_playlistDurationSwitch;
    // The playlist columns' text colors by pair base (kVibeThemeColorPlaylist*
    // text bases): the switch, and the well-pair row it reveals.
    NSMutableDictionary<NSString *, NSSwitch *> *_playlistColorSwitches;
    NSMutableDictionary<NSString *, SettingsRowView *> *_playlistColorRows;
    // Every Dark/Light well pair, for the fixed-theme collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    // Every themed color well → the pair's base key, its side and the effect
    // its drag requests (wellForDark:base:effect:). One action, one refresh
    // loop and one seed walk serve all of them.
    NSMapTable<NSColorWell *, NSDictionary *> *_wellBindings;
    NSPopUpButton *_waveformPopUp;
    NSSlider *_waveformBarDensitySlider;
    NSTextField *_waveformBarDensityValue;
    NSSlider *_waveformBarWidthSlider;
    NSTextField *_waveformBarWidthValue;
    NSPopUpButton *_waveformThemePopUp;
    // A played/unplayed pair per appearance — one pair cannot read on both
    // backdrops.
    SettingsRowView *_customDarkRow, *_customLightRow;
    NSPopUpButton *_playlistBackgroundPopUp;
    SettingsRowView *_playlistBackgroundColorsRow;
    NSPopUpButton *_playlistTintPopUp;
    SettingsRowView *_playlistTintDarkRow, *_playlistTintLightRow;
    NSTextField *_titleFontValue, *_artistFontValue, *_infoFontValue, *_playlistFontValue;
    NSTextField *_playlistDurationFontValue;
    // The font panel's target slot, carried as the Select buttons' tags. None
    // while the panel is not editing a slot; changeFont: no-ops then, which is
    // what keeps a stray panel from restyling anything.
    VibeFontSlot _fontEditingSlot;
}

#pragma mark - Implemented in SettingsAppearanceViewController.m

// The page swap: hides the list sections and shows the editor container, or
// the reverse, and retitles the window. The editor's layout resolver ends
// with it, because the resolver is the one pass both pages run through.
- (void)applyEditorVisibility;

// The window title for the page showing: Theme: <name> on the editor — the
// Name field's live text while it is being edited — Appearance otherwise.
- (void)applyEditorTitle;

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect;
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect continuous:(BOOL)continuous;

// The waveform style popup, built once per surface: the editor's Style row
// and the list page's shortcut are twins, and the shared action re-selects
// the other. selectWaveformStyle:in: shows the default style for an unknown
// persisted identifier — the waveform view's own fallback.
- (NSPopUpButton *)waveformStylePopUpButton;
- (NSImageView *)waveformPreviewView;
- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp;

// Copies the active working record and edits it, preserving built-in changes.
// Shared by Customize, the Add menu and the editor's Duplicate button.
- (IBAction)duplicateTheme:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
