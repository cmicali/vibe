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

static const CGFloat kAppearancePaneHeight = 318;
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
    NSPopUpButton *_waveformPopUp;
    NSPopUpButton *_waveformThemePopUp;
    // A played/unplayed pair per appearance — one pair cannot read on both
    // backdrops.
    NSColorWell *_customDarkPlayedWell;
    NSColorWell *_customDarkUnplayedWell;
    NSColorWell *_customLightPlayedWell;
    NSColorWell *_customLightUnplayedWell;
    // The custom-color wells' grid rows, hidden unless the theme is custom.
    // Built always and toggled, so the walker and the layout stay stable.
    NSGridRow *_customDarkRow;
    NSGridRow *_customLightRow;
    NSPopUpButton *_waveformDragPopUp;
    NSButton *_fileInfoCheckbox;
    NSButton *_timeTotalRadio;
    NSButton *_timeRemainingRadio;
    NSPopUpButton *_keyNotationPopUp;
    NSButton *_keyColorsCheckbox;
}

- (void)loadView {
    _appearancePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(appearanceChanged:)];
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_SYSTEM];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagSystem;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_LIGHT];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagLight;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_DARK];
    _appearancePopUp.lastItem.tag = VibeAppearanceTagDark;

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

    // Identifiers in representedObject as above. No live-apply hook: the
    // waveform view reads the setting per mouse-down.
    _waveformDragPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformDragChanged:)];
    [_waveformDragPopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_DRAG_WINDOW];
    _waveformDragPopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW;
    [_waveformDragPopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_DRAG_SEEK];
    _waveformDragPopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_DRAG_SEEK;

    _customDarkPlayedWell = [self customColorWell];
    _customDarkUnplayedWell = [self customColorWell];
    _customLightPlayedWell = [self customColorWell];
    _customLightUnplayedWell = [self customColorWell];
    NSStackView *customDarkColors = [self customColorPairWithPlayed:_customDarkPlayedWell
                                                           unplayed:_customDarkUnplayedWell];
    NSStackView *customLightColors = [self customColorPairWithPlayed:_customLightPlayedWell
                                                            unplayed:_customLightUnplayedWell];

    _fileInfoCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_FILE_INFO
                                             target:self action:@selector(toggleFileInfo:)];

    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(timeDisplayChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(timeDisplayChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;

    // Identifiers in representedObject, localized names in the titles — the
    // same split as the waveform styles above.
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(keyNotationChanged:)];
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_CAMELOT];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_MUSICAL];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_MUSICAL;

    _keyColorsCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_KEY_COLORS
                                              target:self action:@selector(toggleKeyColors:)];

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_APPEARANCE_LABEL], _appearancePopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_LABEL], _waveformPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_THEME_LABEL], _waveformThemePopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL], customDarkColors],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL], customLightColors],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_DRAG_LABEL], _waveformDragPopUp],
        @[NSGridCell.emptyContentView, _fileInfoCheckbox],
        @[[NSTextField labelWithString:STR_SETTINGS_TIME_LABEL], timeRadios],
        @[[NSTextField labelWithString:STR_SETTINGS_KEY_NOTATION_LABEL], _keyNotationPopUp],
        @[NSGridCell.emptyContentView, _keyColorsCheckbox],
    ]];
    _customDarkRow = [grid cellForView:customDarkColors].row;
    _customLightRow = [grid cellForView:customLightColors].row;
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kAppearancePaneHeight) grid:grid];
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

- (NSColorWell *)customColorWell {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = @selector(customColorChanged:);
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
    BOOL customHidden = ![theme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _customDarkRow.hidden = customHidden;
    _customLightRow.hidden = customHidden;
    AppSettings *settings = AppSettings.sharedInstance;
    _customDarkPlayedWell.color = [settings waveformCustomPlayedColorForDark:YES]
            ?: DefaultCustomPlayedColor(YES);
    _customDarkUnplayedWell.color = [settings waveformCustomUnplayedColorForDark:YES]
            ?: DefaultCustomUnplayedColor(YES);
    _customLightPlayedWell.color = [settings waveformCustomPlayedColorForDark:NO]
            ?: DefaultCustomPlayedColor(NO);
    _customLightUnplayedWell.color = [settings waveformCustomUnplayedColorForDark:NO]
            ?: DefaultCustomUnplayedColor(NO);

    // The getter is normalized, so a match always exists.
    NSString *dragBehavior = AppSettings.sharedInstance.waveformDragBehavior;
    for (NSMenuItem *item in _waveformDragPopUp.itemArray) {
        if ([item.representedObject isEqualToString:dragBehavior]) {
            [_waveformDragPopUp selectItem:item];
            break;
        }
    }

    _fileInfoCheckbox.state = AppSettings.sharedInstance.showFileInfo ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL remaining = AppSettings.sharedInstance.showRemainingTime;
    _timeTotalRadio.state = remaining ? NSControlStateValueOff : NSControlStateValueOn;
    _timeRemainingRadio.state = remaining ? NSControlStateValueOn : NSControlStateValueOff;

    NSString *notation = AppSettings.sharedInstance.keyNotation;
    for (NSMenuItem *item in _keyNotationPopUp.itemArray) {
        if ([item.representedObject isEqualToString:notation]) {
            [_keyNotationPopUp selectItem:item];
            break;
        }
    }
    _keyColorsCheckbox.state = AppSettings.sharedInstance.keyColorsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
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
    _customDarkRow.hidden = !custom;
    _customLightRow.hidden = !custom;
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

- (void)waveformDragChanged:(id)sender {
    AppSettings.sharedInstance.waveformDragBehavior = _waveformDragPopUp.selectedItem.representedObject;
}

- (void)toggleFileInfo:(id)sender {
    AppSettings.sharedInstance.showFileInfo = (_fileInfoCheckbox.state == NSControlStateValueOn);
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
    AppSettings.sharedInstance.keyColorsEnabled = (_keyColorsCheckbox.state == NSControlStateValueOn);
    [self.playerController refreshKeyDisplay];
}

@end
