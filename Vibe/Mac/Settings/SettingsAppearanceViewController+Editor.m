//
//  SettingsAppearanceViewController+Editor.m
//  Vibe
//

#import "SettingsAppearanceViewController+Editor.h"
#import "SettingsAppearanceViewControllerInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Fonts.h"
#import "NSImage+Util.h"
#import "VibeStrings.h"

static const CGFloat kAlbumArtPreviewSize = 64;
// The two corner badges over an artwork preview — the clear ✕ and the
// missing-image (!) — sized as one pair. The box carries a little more than
// the glyph, which is the inset they sit at; scaling both by the same factor
// keeps that. SF Symbols quantize a point size to whole points, so the glyph
// lands near, not exactly on, the box's own ratio.
static const CGFloat kAlbumArtBadgeSize = 22.5;       // 18 * 1.25
static const CGFloat kAlbumArtBadgePointSize = 16.25; // NSFont.systemFontSize * 1.25
// Both badges sit fully INSIDE the preview, at this inset from its corners.
// They stay inside deliberately: a subview hanging past its superview's bounds
// is not hit-tested, which would cost the (!) its tooltip and the ✕ most of its
// click target.
static const CGFloat kAlbumArtBadgeInset = 1.5;

// A color well's binding to one side of its theme pair; see wellForDark:base:effect:.
static NSString *const kWellBase = @"base";
static NSString *const kWellEffect = @"effect";
static NSString *const kWellDark = @"dark";

// TRAP: the editor page's document view must be FLIPPED. An unflipped one
// puts the document's top at its maxY — a moving target — while the clip view
// keeps its bounds origin across geometry changes, so every relayout stranded
// the content further off the top edge: the first card's top slid from its
// correct 86 points to 72, then to 28 on a pane switch away and back, then to
// -132 after a window resize, each time hiding more of the page under the
// toolbar with no scroll gesture involved. Auto layout is flip-agnostic, so
// the stack lays out identically either way; only the clip's idea of where
// the top is changes.
@interface SettingsEditorStackView : NSStackView
@end

@implementation SettingsEditorStackView

- (BOOL)isFlipped {
    return YES;
}

@end

// The corner-radius slider, with a tick above and below the track at the
// factory default — the visual for the action's magnetic detent. NSSlider's
// own tick marks are evenly spaced and single-sided, so the pair is drawn
// here; the knob geometry mirrors AppKit's linear layout (half the knob
// inset at each end).
@interface VibeDetentSlider : NSSlider
@end

@implementation VibeDetentSlider

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.maxValue <= self.minValue) {
        return;
    }
    CGFloat knob = ((NSSliderCell *)self.cell).knobThickness;
    CGFloat fraction = (kVibeThemeCornerRadiusDefault - self.minValue)
            / (self.maxValue - self.minValue);
    CGFloat x = round(knob / 2 + fraction * (NSWidth(self.bounds) - knob));
    CGFloat midY = NSMidY(self.bounds);
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.6] setFill];
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY + 5, 1, 4), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY - 9, 1, 4), NSCompositingOperationSourceOver);
}

@end

@implementation SettingsAppearanceViewController (Editor)

#pragma mark - Construction

// A well bound to one side of a themed color pair, by the pair's base key: it
// reads its color through the theme's display accessor (the override, or the
// unset slot's constant), writes it through the base setter, and requests the
// effect. Alpha is part of the choice: a fill's strength, the solid
// background's opacity, a waveform side's resting level.
- (NSColorWell *)wellForDark:(BOOL)isDark base:(NSString *)base effect:(VibeSettingsLiveEffect)effect {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = @selector(colorWellChanged:);
    if (!_wellBindings) {
        _wellBindings = [NSMapTable strongToStrongObjectsMapTable];
    }
    [_wellBindings setObject:@{kWellBase: base, kWellEffect: @(effect), kWellDark: @(isDark)}
                      forKey:well];
    if (@available(macOS 14.0, *)) {
        well.supportsAlpha = YES;
    } else {
        // Pre-14 a well follows the shared panel, and nothing else in the app
        // opens it, so the global flag is safe.
        NSColorPanel.sharedColorPanel.showsAlpha = YES;
    }
    [well.widthAnchor constraintEqualToConstant:44].active = YES;
    [well.heightAnchor constraintEqualToConstant:24].active = YES;
    return well;
}

// [well caption] [well caption] — one row per themed color pair, Dark/Light
// or the waveform's Played/Unplayed.
- (NSStackView *)wellPair:(NSView *)first caption:(NSString *)firstCaption
                     well:(NSView *)second caption:(NSString *)secondCaption {
    NSTextField *firstLabel = [NSTextField labelWithString:firstCaption];
    NSTextField *secondLabel = [NSTextField labelWithString:secondCaption];
    firstLabel.textColor = NSColor.secondaryLabelColor;
    secondLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *pair = [NSStackView stackViewWithViews:
            @[first, firstLabel, second, secondLabel]];
    pair.spacing = 6;
    [pair setCustomSpacing:16 afterView:firstLabel];
    return pair;
}

- (NSStackView *)darkLightPairWithDark:(NSView *)dark light:(NSView *)light {
    NSStackView *pair = [self wellPair:dark caption:STR_SETTINGS_THEME_DARK
                                  well:light caption:STR_SETTINGS_THEME_LIGHT];
    if (!_darkLightPairs) {
        _darkLightPairs = [NSMutableArray array];
    }
    [_darkLightPairs addObject:pair];
    return pair;
}

// Both sides of one themed color pair as the Dark/Light row control.
- (NSStackView *)darkLightPairForBase:(NSString *)base effect:(VibeSettingsLiveEffect)effect {
    return [self darkLightPairWithDark:[self wellForDark:YES base:base effect:effect]
                                 light:[self wellForDark:NO base:base effect:effect]];
}

// A font row's trailing cluster: the current choice, then Select…, which
// opens the font panel onto that slot.
- (NSStackView *)fontClusterForSlot:(VibeFontSlot)slot valueLabel:(NSTextField **)outLabel {
    NSTextField *value = [NSTextField labelWithString:@""];
    value.textColor = NSColor.secondaryLabelColor;
    NSButton *select = [NSButton buttonWithTitle:STR_SETTINGS_THEME_FONT_SELECT
                                          target:self action:@selector(selectFont:)];
    select.tag = slot;
    *outLabel = value;
    NSStackView *cluster = [NSStackView stackViewWithViews:@[value, select]];
    cluster.spacing = 10;
    return cluster;
}

// One side of the Default artwork pair: a preview of that side's resolved
// placeholder as the click target (click picks a custom image), with a
// hover-revealed clear badge over its corner while a custom image is set.
// The badge is a real button so the walker can address it by its undrawn
// title. System Settings appearance-picker shape.
- (NSView *)albumArtClusterForDark:(BOOL)isDark {
    NSButton *preview = [NSButton buttonWithImage:[AppTheme imageForDefaultArtwork:@""]
                                           target:self action:@selector(chooseAlbumArt:)];
    preview.bordered = NO;
    preview.title = @""; // the factory's "Button" would name it in the walker
    preview.wantsLayer = YES;
    preview.layer.cornerRadius = 6;
    preview.layer.masksToBounds = YES;
    ((NSButtonCell *)preview.cell).imageScaling = NSImageScaleProportionallyUpOrDown;
    NSButton *clear = [NSButton buttonWithImage:[NSImage symbolNamed:@"xmark.circle.fill"
            pointSize:kAlbumArtBadgePointSize weight:NSFontWeightRegular
              palette:@[NSColor.whiteColor, [NSColor colorWithWhite:0 alpha:0.6]]
            accessibilityDescription:STR_SETTINGS_THEME_ALBUM_ART_CLEAR]
                                         target:self action:@selector(clearCustomArtwork:)];
    clear.bordered = NO;
    clear.title = STR_SETTINGS_THEME_ALBUM_ART_CLEAR; // image-only: named, never drawn
    clear.imagePosition = NSImageOnly;
    clear.hidden = YES;
    // The missing-image badge mirrors that clear badge across the preview, and
    // is NOT hover-gated: it reports a state rather than offering an action,
    // and a warning nobody can see without hovering the thing it warns about
    // is no warning. An image view, not a button — there is nothing to press,
    // and a button would promise one to VoiceOver.
    NSImageView *missing = [NSImageView imageViewWithImage:[NSImage
            symbolNamed:@"exclamationmark.circle.fill"
              pointSize:kAlbumArtBadgePointSize weight:NSFontWeightRegular
                palette:@[NSColor.whiteColor, NSColor.systemRedColor]
            accessibilityDescription:STR_SETTINGS_THEME_ALBUM_ART_MISSING]];
    missing.toolTip = STR_SETTINGS_THEME_ALBUM_ART_MISSING;
    missing.accessibilityLabel = STR_SETTINGS_THEME_ALBUM_ART_MISSING;
    missing.hidden = YES;
    NSView *cluster = [[NSView alloc] initWithFrame:NSZeroRect];
    cluster.translatesAutoresizingMaskIntoConstraints = NO;
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    missing.translatesAutoresizingMaskIntoConstraints = NO;
    [cluster addSubview:preview];
    [cluster addSubview:clear];
    [cluster addSubview:missing];
    [NSLayoutConstraint activateConstraints:@[
        [cluster.widthAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [cluster.heightAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [preview.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor],
        [preview.topAnchor constraintEqualToAnchor:cluster.topAnchor],
        [preview.bottomAnchor constraintEqualToAnchor:cluster.bottomAnchor],
        // Pinned to the glyph's size: the undrawn title still feeds the
        // button's intrinsic width, which stretched it across the preview.
        [clear.widthAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [clear.heightAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [clear.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                        constant:kAlbumArtBadgeInset],
        [clear.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor
                                             constant:-kAlbumArtBadgeInset],
        [missing.widthAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [missing.heightAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [missing.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                          constant:kAlbumArtBadgeInset],
        [missing.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor
                                              constant:kAlbumArtBadgeInset],
    ]];
    // The controller owns the hover tracking; userInfo names the side, since
    // both clusters share one owner. ActiveInActiveApp, not ActiveInKeyWindow:
    // the font or color panel is often key while this page is edited, and the
    // badge must still appear. Posted debug events cannot fire it — the window
    // server drives tracking areas — so a scripted clear needs a real hover
    // (input.swift).
    [cluster addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                    | NSTrackingInVisibleRect
            owner:self userInfo:@{@"artClearForDark": @(isDark)}]];
    if (isDark) {
        _artDarkPreviewButton = preview;
        _artDarkClearButton = clear;
        _artDarkMissingBadge = missing;
    } else {
        _artLightPreviewButton = preview;
        _artLightClearButton = clear;
        _artLightMissingBadge = missing;
    }
    return cluster;
}

- (void)buildEditorPage {
    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _nameField.delegate = self;
    [_nameField.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _nameRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_NAME_LABEL control:_nameField];
    _duplicateButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_DUPLICATE
                                          target:self action:@selector(duplicateTheme:)];
    _builtInRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUILT_IN_CAPTION
                                        control:_duplicateButton];

    _modePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                     action:@selector(themeModeChanged:)];
    [self addItem:STR_SETTINGS_THEME_MODE_DUAL value:SETTINGS_VALUE_THEME_MODE_DUAL to:_modePopUp];
    [self addItem:STR_SETTINGS_THEME_MODE_SINGLE value:SETTINGS_VALUE_THEME_MODE_SINGLE to:_modePopUp];

    // Default artwork follows the color pairs: one preview per appearance
    // under Light & Dark Modes, collapsing to the dark-keyed one — the single
    // slot's home — under Single Mode.
    NSStackView *artPair = [self darkLightPairWithDark:[self albumArtClusterForDark:YES]
                                                 light:[self albumArtClusterForDark:NO]];

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_backgroundPopUp];
    _backgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_COLORS
            control:[self darkLightPairForBase:kVibeThemeColorWindowBackground
                                        effect:VibeSettingsLiveEffectWindowChrome]];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_windowTintPopUp];
    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorWindowTint effect:VibeSettingsLiveEffectWindowTint]];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorWindowTint effect:VibeSettingsLiveEffectWindowTint]];

    _cornerRadiusSlider = [VibeDetentSlider sliderWithValue:kVibeThemeCornerRadiusDefault
                                                   minValue:0 maxValue:kVibeThemeCornerRadiusMax
                                                     target:self action:@selector(cornerRadiusChanged:)];
    _cornerRadiusSlider.continuous = YES;
    [_cornerRadiusSlider.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _cornerRadiusValue = [NSTextField labelWithString:@""];
    _cornerRadiusValue.textColor = NSColor.secondaryLabelColor;
    // Right-aligned at a fixed width, so the readout's changing digit count
    // never nudges the slider.
    _cornerRadiusValue.alignment = NSTextAlignmentRight;
    [_cornerRadiusValue.widthAnchor constraintEqualToConstant:50].active = YES;
    NSStackView *radiusCluster = [NSStackView stackViewWithViews:
            @[_cornerRadiusSlider, _cornerRadiusValue]];
    radiusCluster.spacing = 10;

    _playlistBackgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                                   action:@selector(playlistBackgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_playlistBackgroundPopUp];

    _fileInfoSwitch = [self switchWithAction:@selector(toggleFileInfo:)];
    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(timeDisplayChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(timeDisplayChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;
    _showBPMSwitch = [self switchWithAction:@selector(toggleShowBPM:)];
    _showKeySwitch = [self switchWithAction:@selector(toggleShowKey:)];
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(keyNotationChanged:)];
    [self addItem:STR_SETTINGS_KEY_NOTATION_CAMELOT value:SETTINGS_VALUE_KEY_NOTATION_CAMELOT to:_keyNotationPopUp];
    [self addItem:STR_SETTINGS_KEY_NOTATION_MUSICAL value:SETTINGS_VALUE_KEY_NOTATION_MUSICAL to:_keyNotationPopUp];
    _keyColorsSwitch = [self switchWithAction:@selector(toggleKeyColors:)];

    // Title and artist paint the playlist rows too; info and time appear only
    // in the header, so their drags skip the table reload.
    NSStackView *titleColors = [self darkLightPairForBase:kVibeThemeColorTitle
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *artistColors = [self darkLightPairForBase:kVibeThemeColorArtist
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *infoColors = [self darkLightPairForBase:kVibeThemeColorInfo
            effect:VibeSettingsLiveEffectTrackDisplay];
    NSStackView *timeColors = [self darkLightPairForBase:kVibeThemeColorTime
            effect:VibeSettingsLiveEffectTrackDisplay];

    _waveformPopUp = [self waveformStylePopUpButton];
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];

    _waveformGradientSwitch = [self switchWithAction:@selector(toggleWaveformGradient:)];
    _playlistArtworkSwitch = [self switchWithAction:@selector(togglePlaylistArtwork:)];
    _playlistDurationSwitch = [self switchWithAction:@selector(togglePlaylistDuration:)];
    NSStackView *(^customWells)(BOOL) = ^(BOOL dark) {
        return [self wellPair:[self wellForDark:dark base:kVibeThemeColorWaveformPlayed
                                         effect:VibeSettingsLiveEffectWaveformTheme]
                      caption:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED
                         well:[self wellForDark:dark base:kVibeThemeColorWaveformUnplayed
                                         effect:VibeSettingsLiveEffectWaveformTheme]
                      caption:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
    };
    _customDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                           control:customWells(YES)];
    _customLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
                                            control:customWells(NO)];

    // The playlist background is one layer color the cells never read, and
    // the row fills are read per draw, so their drags take the lighter effects
    // rather than the full PlaylistAppearance rebuild.
    _playlistBackgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS
            control:[self darkLightPairForBase:kVibeThemeColorPlaylistBackground
                                        effect:VibeSettingsLiveEffectPlaylistBackground]];

    // The playlist's tint mirrors the window's: the same three choices, the
    // same custom-color rows shown only under Custom.
    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    _playlistTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];
    _playlistTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];

    NSStackView *playingRowColors = [self darkLightPairForBase:kVibeThemeColorPlaylistPlayingRow
                                                        effect:VibeSettingsLiveEffectPlaylistRowFills];
    NSStackView *selectedRowColors = [self darkLightPairForBase:kVibeThemeColorPlaylistSelectedRow
                                                         effect:VibeSettingsLiveEffectPlaylistRowFills];

    NSTextField *titleFontValue = nil, *infoFontValue = nil, *playlistFontValue = nil;
    NSStackView *titleFontCluster = [self fontClusterForSlot:VibeFontSlotTitle valueLabel:&titleFontValue];
    NSTextField *artistFontValue = nil;
    NSStackView *artistFontCluster = [self fontClusterForSlot:VibeFontSlotArtist valueLabel:&artistFontValue];
    NSStackView *infoFontCluster = [self fontClusterForSlot:VibeFontSlotInfo valueLabel:&infoFontValue];
    NSStackView *playlistFontCluster = [self fontClusterForSlot:VibeFontSlotPlaylist valueLabel:&playlistFontValue];
    NSTextField *playlistDurationFontValue = nil;
    NSStackView *playlistDurationFontCluster =
            [self fontClusterForSlot:VibeFontSlotPlaylistDuration
                          valueLabel:&playlistDurationFontValue];
    _titleFontValue = titleFontValue;
    _artistFontValue = artistFontValue;
    _infoFontValue = infoFontValue;
    _playlistFontValue = playlistFontValue;
    _playlistDurationFontValue = playlistDurationFontValue;

    // The Info section is captured so its rows can be disabled as a group
    // when Show file info is off (see resolveLayoutStateFromSettings).
    _infoSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_INFO control:infoFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO control:infoColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES control:timeColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
    ]];

    NSArray<NSView *> *sections = @[
        // The pair swaps visibility — exactly one shows — so the second row
        // must not keep the between-rows hairline the section stamps on it.
        [SettingsSectionView sectionWithRows:@[_builtInRow, _nameRow]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APPEARANCE control:_modePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_LABEL control:_backgroundPopUp],
            _backgroundColorsRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_BACKGROUND_TINT_LABEL control:_windowTintPopUp],
            _windowTintDarkRow,
            _windowTintLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CORNER_RADIUS control:radiusCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYER_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_ALBUM_ART control:artPair],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_MAIN control:titleFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE control:titleColors],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_ARTIST control:artistFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST control:artistColors],
        ]],
        _infoSection,
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LABEL control:_waveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_THEME_LABEL control:_waveformThemePopUp],
            _customDarkRow,
            _customLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GRADIENT control:_waveformGradientSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND
                    control:_playlistBackgroundPopUp],
            _playlistBackgroundColorsRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_TINT
                    control:_playlistTintPopUp],
            _playlistTintDarkRow,
            _playlistTintLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST control:playlistFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST_DURATION
                    control:playlistDurationFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_ARTWORK
                    control:_playlistArtworkSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_DURATION_COLUMN
                    control:_playlistDurationSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW control:playingRowColors],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW control:selectedRowColors],
        ]],
    ];

    _nameRow.showsTopSeparator = NO;
    SettingsEditorStackView *editorStack =
            [[SettingsEditorStackView alloc] initWithFrame:NSZeroRect];
    for (NSView *section in sections) {
        [editorStack addArrangedSubview:section];
    }
    _editorStack = editorStack;
    _editorStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _editorStack.alignment = NSLayoutAttributeLeading;
    _editorStack.spacing = 20;
    _editorStack.translatesAutoresizingMaskIntoConstraints = NO;
    _editorStack.wantsLayer = YES;
    for (NSView *section in sections) {
        [section.widthAnchor constraintEqualToAnchor:_editorStack.widthAnchor].active = YES;
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    // Without this, macOS 26 associates the scroll view with the titlebar
    // above it and builds a scroll pocket — a full-column blur band whose
    // hard bottom edge reads as a stray hairline over the editor page. The
    // scroll view starts below the toolbar, so there is nothing to inset.
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = _editorStack;

    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    [container addSubview:scroll];
    [self.view addSubview:container];
    _detailContainer = container;

    NSLayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:kPanePadding],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kPanePadding],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPanePadding],
        [container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-kPanePadding],
        [scroll.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        // The standard vertical-scroll pinning — top, leading and width, the
        // height left to the content. What keeps the resting position at the
        // top through a relayout is the document view being flipped, above.
        [_editorStack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_editorStack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [_editorStack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
}

#pragma mark - State

- (void)resolveLayoutStateFromSettings {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:
            AppSettings.sharedInstance.activeThemeIdentifier];
    _nameRow.hidden = builtIn;
    _builtInRow.hidden = !builtIn;
    // A single-mode theme has one color per field, so every Dark/Light pair
    // collapses to one well — the dark-keyed well, the single slot's home —
    // with the captions hidden, and the per-side rows keep only that one.
    BOOL single = theme.isSingleMode;
    // The per-side rows lose their side with it: one color, so "Dark color"
    // names a half the theme does not have — and that title is what the
    // debug walker addresses the row by.
    [_windowTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_playlistTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                             : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_customDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLORS_LABEL
                                       : STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL];
    for (NSStackView *pair in _darkLightPairs) {
        NSArray<NSView *> *views = pair.arrangedSubviews; // well, caption, well, caption
        views[1].hidden = single;
        views[2].hidden = single;
        views[3].hidden = single;
    }
    BOOL customTheme = [theme.waveformTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _customDarkRow.hidden = !customTheme;
    _customLightRow.hidden = !customTheme || single;
    BOOL customTint = [theme.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _windowTintDarkRow.hidden = !customTint;
    _windowTintLightRow.hidden = !customTint || single;
    _backgroundColorsRow.hidden = ![theme.windowBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL customPlaylistTint = [theme.playlistTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _playlistTintDarkRow.hidden = !customPlaylistTint;
    _playlistTintLightRow.hidden = !customPlaylistTint || single;
    _playlistBackgroundColorsRow.hidden = ![theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    [self applyEditorVisibility];
}

// One depth-first descendant walk; the leaf actions (enable, deactivate)
// ride it rather than re-rolling the recursion each time.
static void ForEachDescendantView(NSView *view, void (^block)(NSView *)) {
    for (NSView *subview in view.subviews) {
        block(subview);
        ForEachDescendantView(subview, block);
    }
}

static void SetDescendantControlsEnabled(NSView *view, BOOL enabled) {
    ForEachDescendantView(view, ^(NSView *subview) {
        if ([subview isKindOfClass:NSControl.class]) {
            ((NSControl *)subview).enabled = enabled;
        }
    });
}

// The editor, from the working theme. (The name/built-in row swap lives in
// resolveLayoutStateFromSettings with the other conditional rows.)
- (void)refreshEditorFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    NSString *active = settings.activeThemeIdentifier;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    // Skip while the field editor is open, or a refresh mid-type (a menu
    // open/close, the window regaining key) would silently discard the edit —
    // unless the active theme changed under it: then the edit belongs to a
    // theme this page no longer shows, and keeping it would commit onto the
    // wrong one, so it is dropped instead.
    if (_nameField.currentEditor != nil &&
        ![active isEqualToString:_nameFieldThemeIdentifier]) {
        [_nameField abortEditing];
    }
    if (_nameField.currentEditor == nil) {
        _nameField.stringValue = builtIn ? @"" : ([settings displayNameForThemeIdentifier:active] ?: @"");
        _nameFieldThemeIdentifier = active;
    }

    [self selectValue:theme.mode in:_modePopUp];
    [self selectValue:theme.windowBackgroundStyle in:_backgroundPopUp];
    [self selectValue:theme.windowTint in:_windowTintPopUp];
    for (NSColorWell *well in _wellBindings) {
        NSDictionary *binding = [_wellBindings objectForKey:well];
        well.color = [theme displayColorForBase:binding[kWellBase] dark:[binding[kWellDark] boolValue]];
    }
    _cornerRadiusSlider.doubleValue = theme.windowCornerRadius;
    [self refreshCornerRadiusValue];

    _fileInfoSwitch.state = StateForBOOL(theme.showFileInfo);
    BOOL remaining = theme.showRemainingTime;
    _timeTotalRadio.state = StateForBOOL(!remaining);
    _timeRemainingRadio.state = StateForBOOL(remaining);
    _showBPMSwitch.state = StateForBOOL(theme.showBPM);
    BOOL showKey = theme.showKey;
    _showKeySwitch.state = StateForBOOL(showKey);
    [self selectValue:theme.keyNotation in:_keyNotationPopUp];
    _keyColorsSwitch.state = StateForBOOL(theme.keyColorsEnabled);

    [self selectWaveformStyle:theme.waveformStyle in:_waveformPopUp];
    [self selectValue:theme.waveformTheme in:_waveformThemePopUp];
    _waveformGradientSwitch.state = StateForBOOL(theme.waveformGradient);
    _playlistArtworkSwitch.state = StateForBOOL(theme.showPlaylistArtworkColumn);
    _artDarkPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:YES]];
    _artLightPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:NO]];
    _artDarkClearButton.hidden = YES;
    _artLightClearButton.hidden = YES;
    _artDarkMissingBadge.hidden =
            ![AppTheme defaultArtworkIsMissing:[theme defaultArtworkForDark:YES]];
    _artLightMissingBadge.hidden =
            ![AppTheme defaultArtworkIsMissing:[theme defaultArtworkForDark:NO]];
    _playlistDurationSwitch.state = StateForBOOL(theme.showPlaylistDurationColumn);
    [self selectValue:theme.playlistBackgroundStyle in:_playlistBackgroundPopUp];
    [self selectValue:theme.playlistTint in:_playlistTintPopUp];

    [self refreshFontValueLabels];

    // Read-only built-ins: every editor control disables, honestly reported
    // by the debug walker; then the always-live sub-rules re-apply.
    SetDescendantControlsEnabled(_editorStack, !builtIn);
    // The built-in page's one live control sits inside the swept stack now
    // that the caption row is a card row: without this, a built-in could
    // never be duplicated from its own page. Observed, not hypothetical.
    _duplicateButton.enabled = YES;
    if (!builtIn) {
        // Everything below Show file info dims when it is off — the header
        // shows none of it, so nothing those rows govern is on screen.
        BOOL info = AppSettings.sharedInstance.currentTheme.showFileInfo;
        SetDescendantControlsEnabled(_infoSection, info);
        _fileInfoSwitch.enabled = YES; // the toggle that governs them stays live
        // Key notation and key colors additionally require Show key.
        _keyNotationPopUp.enabled = info && showKey;
        _keyColorsSwitch.enabled = info && showKey;
    }
    if (builtIn) {
        [self closeEditorPanels];
    }
}

- (void)refreshFontValueLabels {
    NSDictionary<NSNumber *, NSTextField *> *labels = @{
        @(VibeFontSlotTitle): _titleFontValue,
        @(VibeFontSlotArtist): _artistFontValue,
        @(VibeFontSlotInfo): _infoFontValue,
        @(VibeFontSlotPlaylist): _playlistFontValue,
        @(VibeFontSlotPlaylistDuration): _playlistDurationFontValue,
    };
    for (NSNumber *slot in labels) {
        NSFont *font = [Fonts fontForSlot:slot.integerValue bold:NO];
        labels[slot].stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_FONT_VALUE,
                font.displayName, (long)lround(font.pointSize)];
    }
}

#pragma mark - Editor: mode and color wells

// Which color slot every consumer reads moves with the mode, so the whole
// theme re-applies.
- (void)themeModeChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.mode =
            _modePopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings]; // ends in resolveLayoutStateFromSettings
}

// Writes each well's displayed color into its slot, so the surface
// immediately matches what the wells show when a popup reveals them. A set
// slot writes its own value back, unchanged; an unset one takes the
// display accessor's constant. Dark wells FIRST: under single mode both
// reads and writes canonicalize to the dark-keyed slot, so the dark pass
// seeds it and the light pass reads that back — the one slot takes the dark
// default with no special case.
- (void)seedWellsIn:(NSArray<NSView *> *)containers {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSMutableArray<NSDictionary *> *bindings = [NSMutableArray array];
    for (NSView *container in containers) {
        ForEachDescendantView(container, ^(NSView *subview) {
            NSDictionary *binding = [subview isKindOfClass:NSColorWell.class]
                    ? [self->_wellBindings objectForKey:(NSColorWell *)subview] : nil;
            if (binding) {
                [bindings addObject:binding];
            }
        });
    }
    for (int darkPass = 1; darkPass >= 0; darkPass--) {
        for (NSDictionary *binding in bindings) {
            BOOL isDark = [binding[kWellDark] boolValue];
            if (isDark == (darkPass == 1)) {
                NSString *base = binding[kWellBase];
                [theme setColor:[theme displayColorForBase:base dark:isDark] forBase:base dark:isDark];
            }
        }
    }
}

// The one action every themed well sends: write the side, request the
// pair's effect.
- (void)colorWellChanged:(NSColorWell *)sender {
    NSDictionary *binding = [_wellBindings objectForKey:sender];
    [AppSettings.sharedInstance.currentTheme setColor:sender.color forBase:binding[kWellBase]
                                                 dark:[binding[kWellDark] boolValue]];
    [self themeFieldDidChange:(VibeSettingsLiveEffect)[binding[kWellEffect] unsignedIntegerValue]];
}

// The one gesture behind every popup that reveals color rows — the two
// background styles, the two tints, the waveform theme: the choice that
// consumes the pair seeds its wells first, so the surface immediately matches
// what they show; then the field, the effect, and the row reveal.
- (void)chooseFromPopUp:(NSPopUpButton *)popUp revealing:(NSString *)revealing
                  wells:(NSArray<NSView *> *)rows effect:(VibeSettingsLiveEffect)effect
                  write:(void (^)(AppTheme *theme, NSString *identifier))write {
    NSString *identifier = popUp.selectedItem.representedObject;
    if ([identifier isEqualToString:revealing]) {
        [self seedWellsIn:rows];
    }
    write(AppSettings.sharedInstance.currentTheme, identifier);
    [self themeFieldDidChange:effect];
    [self resolveLayoutStateFromSettings];
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    [self chooseFromPopUp:_backgroundPopUp revealing:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
                    wells:@[_backgroundColorsRow] effect:VibeSettingsLiveEffectWindowChrome
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowBackgroundStyle = identifier; }];
}

- (void)windowTintChanged:(id)sender {
    [self chooseFromPopUp:_windowTintPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_windowTintDarkRow, _windowTintLightRow] effect:VibeSettingsLiveEffectWindowTint
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowTint = identifier; }];
}

- (void)cornerRadiusChanged:(id)sender {
    // A magnetic detent at the factory radius — the reset, without a button:
    // dragging near the default snaps onto it. The sanitize gate rounds to
    // whole points; the knob re-syncs to what actually landed.
    double radius = _cornerRadiusSlider.doubleValue;
    if (fabs(radius - kVibeThemeCornerRadiusDefault) < 1.5) {
        radius = kVibeThemeCornerRadiusDefault;
    }
    AppSettings.sharedInstance.currentTheme.windowCornerRadius = radius;
    _cornerRadiusSlider.doubleValue = AppSettings.sharedInstance.currentTheme.windowCornerRadius;
    [self refreshCornerRadiusValue];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
}

- (void)refreshCornerRadiusValue {
    _cornerRadiusValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_CORNER_RADIUS_VALUE,
            (long)lround(AppSettings.sharedInstance.currentTheme.windowCornerRadius)];
}

#pragma mark - Editor: default artwork

// The clear badge shows only while there is something to clear: a non-empty
// value in the hovered side's slot, on an editable page. Read live — the
// value, the page and the enable state can all have changed since the last
// hover.
- (void)mouseEntered:(NSEvent *)event {
    NSNumber *side = event.trackingArea.userInfo[@"artClearForDark"];
    if (side == nil) {
        return;
    }
    NSButton *preview = side.boolValue ? _artDarkPreviewButton : _artLightPreviewButton;
    NSButton *clear = side.boolValue ? _artDarkClearButton : _artLightClearButton;
    clear.hidden = !preview.enabled || [AppSettings.sharedInstance.currentTheme
            defaultArtworkForDark:side.boolValue].length == 0;
}

- (void)mouseExited:(NSEvent *)event {
    NSNumber *side = event.trackingArea.userInfo[@"artClearForDark"];
    if (side != nil) {
        (side.boolValue ? _artDarkClearButton : _artLightClearButton).hidden = YES;
    }
}

- (void)clearCustomArtwork:(id)sender {
    [AppSettings.sharedInstance.currentTheme setDefaultArtwork:@""
            forDark:sender == _artDarkClearButton];
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay
            | VibeSettingsLiveEffectPlaylistAppearance];
    [self refreshFromSettings]; // also hides the badge — the cursor is still over it
}

- (void)chooseAlbumArt:(id)sender {
    BOOL isDark = sender == _artDarkPreviewButton;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJPEG, UTTypePNG];
    // The sheet blocks the window, not the menu bar — View > Theme can switch
    // the active theme underneath it, so bind the write to the theme that was
    // active when the panel opened (the async-delivery rule).
    NSString *target = AppSettings.sharedInstance.activeThemeIdentifier;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK || !panel.URL) {
            return;
        }
        if (![AppSettings.sharedInstance.activeThemeIdentifier isEqualToString:target]) {
            // Theme changed under the sheet — drop the pick before it is
            // stored, so nothing is left for the sweep to find.
            [self refreshFromSettings];
            return;
        }
        NSError *error = nil;
        // Read mapped, as the theme import is: the byte cap inside AppTheme
        // rejects an oversized image, but only once the bytes exist, and a
        // mistakenly picked huge file must not be pulled into memory to be
        // told it is too big.
        NSString *stored = [AppTheme storeCustomArtworkData:
                [NSData dataWithContentsOfURL:panel.URL
                                      options:NSDataReadingMappedIfSafe
                                        error:NULL] error:&error];
        if (!stored) {
            [self refreshFromSettings];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = STR_SETTINGS_THEME_ALBUM_ART_INVALID;
            alert.informativeText = STR_SETTINGS_THEME_ALBUM_ART_REQUIREMENTS;
            [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            return;
        }
        [AppSettings.sharedInstance.currentTheme setDefaultArtwork:stored forDark:isDark];
        [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay
                | VibeSettingsLiveEffectPlaylistAppearance];
        [self refreshFromSettings];
    }];
}

#pragma mark - Editor: info display

- (void)toggleFileInfo:(id)sender {
    AppSettings.sharedInstance.currentTheme.showFileInfo = (_fileInfoSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
    // The rows it governs enable/disable with it.
    [self refreshFromSettings];
}

- (void)timeDisplayChanged:(NSButton *)sender {
    AppSettings.sharedInstance.currentTheme.showRemainingTime = (sender == _timeRemainingRadio);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleShowBPM:(id)sender {
    AppSettings.sharedInstance.currentTheme.showBPM = (_showBPMSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleShowKey:(id)sender {
    AppSettings.sharedInstance.currentTheme.showKey = (_showKeySwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
    // With Show key off the two rows below it have nothing to govern, so they
    // dim rather than pretending a write would change anything on screen.
    [self refreshFromSettings];
}

- (void)keyNotationChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleKeyColors:(id)sender {
    AppSettings.sharedInstance.currentTheme.keyColorsEnabled = (_keyColorsSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

#pragma mark - Editor: waveform

- (void)toggleWaveformGradient:(id)sender {
    AppSettings.sharedInstance.currentTheme.waveformGradient =
            (_waveformGradientSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
}

- (void)waveformThemeChanged:(id)sender {
    [self chooseFromPopUp:_waveformThemePopUp revealing:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                    wells:@[_customDarkRow, _customLightRow] effect:VibeSettingsLiveEffectWaveformTheme
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformTheme = identifier; }];
}

#pragma mark - Editor: playlist

- (void)togglePlaylistArtwork:(id)sender {
    AppSettings.sharedInstance.currentTheme.showPlaylistArtworkColumn =
            (_playlistArtworkSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
}

- (void)togglePlaylistDuration:(id)sender {
    AppSettings.sharedInstance.currentTheme.showPlaylistDurationColumn =
            (_playlistDurationSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
}

- (void)playlistBackgroundStyleChanged:(id)sender {
    [self chooseFromPopUp:_playlistBackgroundPopUp revealing:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
                    wells:@[_playlistBackgroundColorsRow] effect:VibeSettingsLiveEffectPlaylistAppearance
                    write:^(AppTheme *theme, NSString *identifier) { theme.playlistBackgroundStyle = identifier; }];
}

- (void)playlistTintChanged:(id)sender {
    [self chooseFromPopUp:_playlistTintPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_playlistTintDarkRow, _playlistTintLightRow] effect:VibeSettingsLiveEffectWindowTint
                    write:^(AppTheme *theme, NSString *identifier) { theme.playlistTint = identifier; }];
}

#pragma mark - Editor: name

// TRAP: the Name field's editor is an NSTextView, which implements changeFont:
// and would eat the font panel's sends to restyle the name. selectFont: parks
// first responder to open the panel clear of it; this is the same trap reached
// from the other side, once the panel is already up.
- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    if (notification.object != _nameField) {
        return;
    }
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object != _nameField) {
        return;
    }
    NSString *active = AppSettings.sharedInstance.activeThemeIdentifier;
    if ([AppTheme isBuiltInIdentifier:active]) {
        return;
    }
    // An edit that outlived a theme switch is dropped, never committed onto
    // the theme that is now active (see _nameFieldThemeIdentifier).
    if (![active isEqualToString:_nameFieldThemeIdentifier]) {
        [self refreshFromSettings];
        return;
    }
    [AppSettings.sharedInstance renameUserThemeWithIdentifier:active
                                                       toName:_nameField.stringValue];
    // The stored name may have been deduped or fallback-named; show what
    // actually landed.
    [self refreshFromSettings];
}

#pragma mark - Editor: fonts

- (void)selectFont:(NSButton *)sender {
    _fontEditingSlot = (VibeFontSlot)sender.tag;
    // TRAP: a focused field editor is an NSTextView, which implements
    // changeFont: and would eat the panel's sends to restyle the Name field —
    // park first responder on the pane's own view before opening the panel.
    [self.view.window makeFirstResponder:self.view];
    NSFontManager *manager = NSFontManager.sharedFontManager;
    [manager setSelectedFont:[Fonts fontForSlot:_fontEditingSlot bold:NO] isMultiple:NO];
    [manager orderFrontFontPanel:self];
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel {
    return NSFontPanelModeMaskCollection | NSFontPanelModeMaskFace | NSFontPanelModeMaskSize;
}

// Continuous browsing in the panel lands here per pick — a live preview for
// free. The store clamps the size; face names resolve through Fonts'
// never-nil fallback at draw time.
- (void)changeFont:(NSFontManager *)sender {
    if (_fontEditingSlot == VibeFontSlotNone) {
        return;
    }
    NSFont *font = [sender convertFont:[Fonts fontForSlot:_fontEditingSlot bold:NO]];
    [AppSettings.sharedInstance.currentTheme setFontFace:font.fontName size:font.pointSize
                                                 forSlot:_fontEditingSlot];
    [self themeFieldDidChange:VibeSettingsLiveEffectFonts
            | VibeSettingsLiveEffectPlaylistAppearance
            | VibeSettingsLiveEffectTrackDisplay];
    [self refreshFontValueLabels];
}

// Editor teardown: close the font panel and deactivate every color well.
// A well stays bound to the shared NSColorPanel until deactivated — disabling
// or hiding it does not — so a well left active on a departed or now read-only
// page would take the panel's next pick. Every caller is a page leave or a
// switch to a built-in.
- (void)closeEditorPanels {
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
    ForEachDescendantView(self.view, ^(NSView *subview) {
        if ([subview isKindOfClass:NSColorWell.class]) {
            [(NSColorWell *)subview deactivate];
        }
    });
}

@end
