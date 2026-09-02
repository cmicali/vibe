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
    SettingsSectionView *_infoSection;
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
    NSButton *_timeTotalRadio, *_timeRemainingRadio;
    NSSwitch *_showBPMSwitch, *_showKeySwitch;
    NSPopUpButton *_keyNotationPopUp;
    NSSwitch *_keyColorsSwitch;
    NSSwitch *_waveformGradientSwitch;
    NSSwitch *_playlistArtworkSwitch;
    NSPopUpButton *_modePopUp;
    NSButton *_artDarkPreviewButton;
    NSButton *_artDarkClearButton;
    NSImageView *_artDarkMissingBadge;
    NSButton *_artLightPreviewButton;
    NSButton *_artLightClearButton;
    NSImageView *_artLightMissingBadge;
    NSSwitch *_playlistDurationSwitch;
    // Every Dark/Light well pair, for the fixed-theme collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    // Every themed color well → the pair's base key, its side and the effect
    // its drag requests (wellForDark:base:effect:). One action, one refresh
    // loop and one seed walk serve all of them.
    NSMapTable<NSColorWell *, NSDictionary *> *_wellBindings;
    NSPopUpButton *_waveformPopUp;
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

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect;

// The waveform style popup, built once per surface: the editor's Style row
// and the list page's shortcut are twins, and the shared action re-selects
// the other. selectWaveformStyle:in: shows the default style for an unknown
// persisted identifier — the waveform view's own fallback.
- (NSPopUpButton *)waveformStylePopUpButton;
- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp;

// Copies the active theme and edits the copy — the Add pulldown's Duplicate
// and the read-only editor page's Duplicate button both mean this.
- (IBAction)duplicateTheme:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
