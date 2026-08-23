//
//  SettingsAppearanceViewController.m
//  Vibe
//

#import "SettingsAppearanceViewController.h"
#import "AppSettings.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Menus.h"
#import "VibeStrings.h"

static const CGFloat kAppearancePopUpWidth = 220;

// Popup tags for the appearance choices; the persisted value is the
// SETTINGS_VALUE_WINDOW_APPEARANCE_* string.
typedef NS_ENUM(NSInteger, VibeAppearanceTag) {
    VibeAppearanceTagSystem = 0,
    VibeAppearanceTagLight,
    VibeAppearanceTagDark,
};

@implementation SettingsAppearanceViewController {
    NSPopUpButton *_appearancePopUp;
    NSPopUpButton *_windowTintPopUp;
    NSColorWell *_windowTintDarkWell;
    NSColorWell *_windowTintLightWell;
    // The tint wells' rows, hidden unless the tint is custom — the same
    // build-always-and-toggle shape as the waveform's custom rows below.
    SettingsRowView *_windowTintDarkRow;
    SettingsRowView *_windowTintLightRow;
    NSPopUpButton *_waveformPopUp;
    NSPopUpButton *_waveformThemePopUp;
    // A played/unplayed pair per appearance — one pair cannot read on both
    // backdrops.
    NSColorWell *_customDarkPlayedWell;
    NSColorWell *_customDarkUnplayedWell;
    NSColorWell *_customLightPlayedWell;
    NSColorWell *_customLightUnplayedWell;
    // The custom-color wells' rows, hidden unless the theme is custom. Built
    // always and toggled, so the walker and the layout stay stable; the
    // section stack closes the gap, separators included.
    SettingsRowView *_customDarkRow;
    SettingsRowView *_customLightRow;
    NSSwitch *_fileInfoSwitch;
    NSButton *_timeTotalRadio;
    NSButton *_timeRemainingRadio;
    NSSwitch *_showBPMSwitch;
    NSSwitch *_showKeySwitch;
    NSPopUpButton *_keyNotationPopUp;
    NSSwitch *_keyColorsSwitch;
}

- (void)loadView {
    _appearancePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(appearanceChanged:)];
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_SYSTEM];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagSystem;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_LIGHT];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagLight;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_DARK];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagDark;

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_MONO];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_MONO;
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_ARTWORK];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;

    _windowTintDarkWell = [self customColorWellWithAction:@selector(windowTintColorChanged:)];
    _windowTintLightWell = [self customColorWellWithAction:@selector(windowTintColorChanged:)];

    // Identifiers travel in representedObject, localized names in the titles
    // — the same split as the View > Waveform menu, and for the same reason:
    // a display name must never reach NSUserDefaults.
    _waveformPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformStyleChanged:)];
    MainPlayerController *player = self.playerController;
    NSArray<NSString *> *styles = [[player availableWaveformStyleIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [[player displayNameForWaveformStyle:a]
                        localizedStandardCompare:[player displayNameForWaveformStyle:b]];
            }];
    for (NSString *identifier in styles) {
        [_waveformPopUp addItemWithTitle:[player displayNameForWaveformStyle:identifier]];
        _waveformPopUp.lastItem.representedObject = identifier;
    }

    // The theme is the palette laid over the style's geometry; identifiers in
    // representedObject as above.
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_MONO];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ORANGE];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ORANGE;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;

    _customDarkPlayedWell = [self customColorWellWithAction:@selector(customColorChanged:)];
    _customDarkUnplayedWell = [self customColorWellWithAction:@selector(customColorChanged:)];
    _customLightPlayedWell = [self customColorWellWithAction:@selector(customColorChanged:)];
    _customLightUnplayedWell = [self customColorWellWithAction:@selector(customColorChanged:)];
    NSStackView *customDarkColors = [self customColorPairWithPlayed:_customDarkPlayedWell
                                                           unplayed:_customDarkUnplayedWell];
    NSStackView *customLightColors = [self customColorPairWithPlayed:_customLightPlayedWell
                                                            unplayed:_customLightUnplayedWell];

    _fileInfoSwitch = [self switchWithAction:@selector(toggleFileInfo:)];

    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(timeDisplayChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(timeDisplayChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;

    _showBPMSwitch = [self switchWithAction:@selector(toggleShowBPM:)];
    _showKeySwitch = [self switchWithAction:@selector(toggleShowKey:)];

    // Identifiers in representedObject, localized names in the titles — the
    // same split as the waveform styles above.
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(keyNotationChanged:)];
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_CAMELOT];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_MUSICAL];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_MUSICAL;

    _keyColorsSwitch = [self switchWithAction:@selector(toggleKeyColors:)];

    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
                                               control:_windowTintDarkWell];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
                                                control:_windowTintLightWell];

    _customDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                           control:customDarkColors];
    _customLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
                                            control:customLightColors];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_LABEL control:_windowTintPopUp],
            _windowTintDarkRow,
            _windowTintLightRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LABEL control:_waveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_THEME_LABEL control:_waveformThemePopUp],
            _customDarkRow,
            _customLightRow,
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
        ]],
    ]];
}

- (NSStackView *)customColorPairWithPlayed:(NSColorWell *)played unplayed:(NSColorWell *)unplayed {
    NSTextField *playedCaption = [NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED];
    NSTextField *unplayedCaption = [NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
    playedCaption.textColor = NSColor.secondaryLabelColor;
    unplayedCaption.textColor = NSColor.secondaryLabelColor;
    NSStackView *pair = [NSStackView stackViewWithViews:@[played, playedCaption, unplayed, unplayedCaption]];
    pair.spacing = 6;
    [pair setCustomSpacing:16 afterView:playedCaption];
    return pair;
}

- (NSColorWell *)customColorWellWithAction:(SEL)action {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = action;
    // The alpha is part of the choice: a color's alpha is its side's resting
    // level (WaveformTheme.h).
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

- (void)resolveLayoutStateFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL customTheme = [settings.waveformTheme
            isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _customDarkRow.hidden = !customTheme;
    _customLightRow.hidden = !customTheme;
    BOOL customTint = [settings.windowTint
            isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _windowTintDarkRow.hidden = !customTint;
    _windowTintLightRow.hidden = !customTint;
}

- (void)refreshFromSettings {
    NSString *style = AppSettings.sharedInstance.windowAppearanceStyle;
    if ([style isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT]) {
        [_appearancePopUp selectItemWithTag:VibeAppearanceTagLight];
    }
    else if ([style isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK]) {
        [_appearancePopUp selectItemWithTag:VibeAppearanceTagDark];
    }
    else {
        [_appearancePopUp selectItemWithTag:VibeAppearanceTagSystem];
    }

    // An unknown persisted identifier renders as the default style — the
    // waveform view's own fallback — so the popup shows that rather than
    // leaving whatever was selected before standing, which would misreport
    // what is on screen.
    NSString *current = AppSettings.sharedInstance.waveformStyle;
    NSMenuItem *match = nil;
    for (NSMenuItem *item in _waveformPopUp.itemArray) {
        if ([item.representedObject isEqualToString:current]) {
            match = item;
            break;
        }
    }
    if (!match) {
        for (NSMenuItem *item in _waveformPopUp.itemArray) {
            if ([item.representedObject isEqualToString:SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT]) {
                match = item;
                break;
            }
        }
    }
    if (match) {
        [_waveformPopUp selectItem:match];
    }

    // The getter is normalized, so an unknown persisted identifier selects
    // White — matching what the waveform actually draws.
    NSString *theme = AppSettings.sharedInstance.waveformTheme;
    for (NSMenuItem *item in _waveformThemePopUp.itemArray) {
        if ([item.representedObject isEqualToString:theme]) {
            [_waveformThemePopUp selectItem:item];
            break;
        }
    }
    AppSettings *settings = AppSettings.sharedInstance;
    _customDarkPlayedWell.color = [settings waveformCustomPlayedColorForDark:YES]
            ?: DefaultCustomPlayedColor(YES);
    _customDarkUnplayedWell.color = [settings waveformCustomUnplayedColorForDark:YES]
            ?: DefaultCustomUnplayedColor(YES);
    _customLightPlayedWell.color = [settings waveformCustomPlayedColorForDark:NO]
            ?: DefaultCustomPlayedColor(NO);
    _customLightUnplayedWell.color = [settings waveformCustomUnplayedColorForDark:NO]
            ?: DefaultCustomUnplayedColor(NO);

    // The getter is normalized, so an unknown persisted identifier selects
    // Artwork color — matching the wash actually on the window.
    NSString *tint = AppSettings.sharedInstance.windowTint;
    for (NSMenuItem *item in _windowTintPopUp.itemArray) {
        if ([item.representedObject isEqualToString:tint]) {
            [_windowTintPopUp selectItem:item];
            break;
        }
    }
    _windowTintDarkWell.color = [AppSettings.sharedInstance windowTintCustomColorForDark:YES]
            ?: DefaultWindowTintColor(YES);
    _windowTintLightWell.color = [AppSettings.sharedInstance windowTintCustomColorForDark:NO]
            ?: DefaultWindowTintColor(NO);

    _fileInfoSwitch.state = AppSettings.sharedInstance.showFileInfo ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL remaining = AppSettings.sharedInstance.showRemainingTime;
    _timeTotalRadio.state = remaining ? NSControlStateValueOff : NSControlStateValueOn;
    _timeRemainingRadio.state = remaining ? NSControlStateValueOn : NSControlStateValueOff;

    _showBPMSwitch.state = AppSettings.sharedInstance.showBPM ? NSControlStateValueOn : NSControlStateValueOff;

    // With Show key off the two rows below it have nothing to govern, so they
    // dim rather than pretending a write would change anything on screen.
    BOOL showKey = AppSettings.sharedInstance.showKey;
    _showKeySwitch.state = showKey ? NSControlStateValueOn : NSControlStateValueOff;
    _keyNotationPopUp.enabled = showKey;
    _keyColorsSwitch.enabled = showKey;
    NSString *notation = AppSettings.sharedInstance.keyNotation;
    for (NSMenuItem *item in _keyNotationPopUp.itemArray) {
        if ([item.representedObject isEqualToString:notation]) {
            [_keyNotationPopUp selectItem:item];
            break;
        }
    }
    _keyColorsSwitch.state = AppSettings.sharedInstance.keyColorsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleShowBPM:(id)sender {
    AppSettings.sharedInstance.showBPM = (_showBPMSwitch.state == NSControlStateValueOn);
    [self.playerController refreshBPMDisplay];
}

- (void)toggleShowKey:(id)sender {
    AppSettings.sharedInstance.showKey = (_showKeySwitch.state == NSControlStateValueOn);
    [self.playerController refreshKeyDisplay];
    [self refreshFromSettings];
}

- (void)appearanceChanged:(id)sender {
    switch (_appearancePopUp.selectedTag) {
        case VibeAppearanceTagLight:
            AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
            break;
        case VibeAppearanceTagDark:
            AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK;
            break;
        default:
            AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT;
            break;
    }
    // A non-menu sender applies the stored setting without rewriting it.
    [self.playerController setAppearance:nil];
}

- (void)waveformStyleChanged:(id)sender {
    [self.playerController applyWaveformStyle:_waveformPopUp.selectedItem.representedObject];
}

// The custom pairs' fallbacks, shared by the wells' display and the seed on
// choosing Custom, so the waveform always matches what the wells show. Their
// alphas are the Mono theme's resting levels; the played hue is the
// appearance's own base.
static NSColor *DefaultCustomPlayedColor(BOOL isDark) {
    return isDark ? [NSColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                  : [NSColor colorWithRed:0 green:0 blue:0 alpha:0.75];
}

static NSColor *DefaultCustomUnplayedColor(BOOL isDark) {
    return [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

- (void)waveformThemeChanged:(id)sender {
    NSString *identifier = _waveformThemePopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    if (custom) {
        // Choosing Custom seeds any unset color from the wells' displayed
        // fallbacks, so the waveform immediately matches what the wells show.
        AppSettings *settings = AppSettings.sharedInstance;
        for (int darkPass = 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![settings waveformCustomPlayedColorForDark:isDark]) {
                [settings setWaveformCustomPlayedColor:DefaultCustomPlayedColor(isDark) forDark:isDark];
            }
            if (![settings waveformCustomUnplayedColorForDark:isDark]) {
                [settings setWaveformCustomUnplayedColor:DefaultCustomUnplayedColor(isDark) forDark:isDark];
            }
        }
    }
    [self animatePaneContentChange:^{
        self->_customDarkRow.hidden = !custom;
        self->_customLightRow.hidden = !custom;
    }];
    [self.playerController applyWaveformTheme:identifier];
}

- (void)customColorChanged:(NSColorWell *)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    if (sender == _customDarkPlayedWell) {
        [settings setWaveformCustomPlayedColor:sender.color forDark:YES];
    } else if (sender == _customDarkUnplayedWell) {
        [settings setWaveformCustomUnplayedColor:sender.color forDark:YES];
    } else if (sender == _customLightPlayedWell) {
        [settings setWaveformCustomPlayedColor:sender.color forDark:NO];
    } else {
        [settings setWaveformCustomUnplayedColor:sender.color forDark:NO];
    }
    [self.playerController refreshWaveformTheme];
}

// The custom wash's fallbacks, shared by the wells' display and the seed on
// choosing Custom, so the window always matches what the wells show. Neutral
// grays in the middle of each appearance's clamp band, at the same alpha the
// artwork wash uses there — a starting point to pick a hue from.
static NSColor *DefaultWindowTintColor(BOOL isDark) {
    return isDark ? [NSColor colorWithWhite:0.14 alpha:0.40]
                  : [NSColor colorWithWhite:0.88 alpha:0.55];
}

- (void)windowTintChanged:(id)sender {
    NSString *identifier = _windowTintPopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    AppSettings *settings = AppSettings.sharedInstance;
    if (custom) {
        // As with the waveform's custom theme: seed any unset color from the
        // wells' displayed fallbacks, so the wash immediately matches them.
        for (int darkPass = 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![settings windowTintCustomColorForDark:isDark]) {
                [settings setWindowTintCustomColor:DefaultWindowTintColor(isDark) forDark:isDark];
            }
        }
    }
    [self animatePaneContentChange:^{
        self->_windowTintDarkRow.hidden = !custom;
        self->_windowTintLightRow.hidden = !custom;
    }];
    settings.windowTint = identifier;
    [self.playerController refreshWindowTint];
}

- (void)windowTintColorChanged:(NSColorWell *)sender {
    [AppSettings.sharedInstance setWindowTintCustomColor:sender.color
                                                 forDark:(sender == _windowTintDarkWell)];
    [self.playerController refreshWindowTint];
}

- (void)toggleFileInfo:(id)sender {
    AppSettings.sharedInstance.showFileInfo = (_fileInfoSwitch.state == NSControlStateValueOn);
    [self.playerController refreshFileInfoDisplay];
}

- (void)timeDisplayChanged:(NSButton *)sender {
    AppSettings.sharedInstance.showRemainingTime = (sender == _timeRemainingRadio);
    [self.playerController refreshTimeDisplay];
}

- (void)keyNotationChanged:(id)sender {
    AppSettings.sharedInstance.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    [self.playerController refreshKeyDisplay];
}

- (void)toggleKeyColors:(id)sender {
    AppSettings.sharedInstance.keyColorsEnabled = (_keyColorsSwitch.state == NSControlStateValueOn);
    [self.playerController refreshKeyDisplay];
}

@end
