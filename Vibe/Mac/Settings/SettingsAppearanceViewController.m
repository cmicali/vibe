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

static const CGFloat kAppearancePaneHeight = 260;
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
    NSColorWell *_customPlayedWell;
    NSColorWell *_customUnplayedWell;
    // The custom-color wells' grid row, hidden unless the theme is custom.
    // Built always and toggled, so the walker and the layout stay stable.
    NSGridRow *_customColorsRow;
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
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_WHITE];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_WHITE;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ORANGE];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ORANGE;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;

    _customPlayedWell = [self customColorWell];
    _customUnplayedWell = [self customColorWell];
    NSTextField *playedCaption = [NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED];
    NSTextField *unplayedCaption = [NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
    playedCaption.textColor = NSColor.secondaryLabelColor;
    unplayedCaption.textColor = NSColor.secondaryLabelColor;
    NSStackView *customColors = [NSStackView stackViewWithViews:@[
            _customPlayedWell, playedCaption, _customUnplayedWell, unplayedCaption]];
    customColors.spacing = 6;
    [customColors setCustomSpacing:16 afterView:playedCaption];

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
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_CUSTOM_LABEL], customColors],
        @[NSGridCell.emptyContentView, _fileInfoCheckbox],
        @[[NSTextField labelWithString:STR_SETTINGS_TIME_LABEL], timeRadios],
        @[[NSTextField labelWithString:STR_SETTINGS_KEY_NOTATION_LABEL], _keyNotationPopUp],
        @[NSGridCell.emptyContentView, _keyColorsCheckbox],
    ]];
    _customColorsRow = [grid cellForView:customColors].row;
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kAppearancePaneHeight) grid:grid];
}

- (NSColorWell *)customColorWell {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = @selector(customColorChanged:);
    // Alpha is the renderers' business — the ramps derive their own.
    if (@available(macOS 14.0, *)) {
        well.supportsAlpha = NO;
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
    _customColorsRow.hidden = ![theme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _customPlayedWell.color = AppSettings.sharedInstance.waveformCustomPlayedColor
            ?: NSColor.whiteColor;
    _customUnplayedWell.color = AppSettings.sharedInstance.waveformCustomUnplayedColor
            ?: [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1];

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

- (void)waveformThemeChanged:(id)sender {
    NSString *identifier = _waveformThemePopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    if (custom) {
        // Choosing Custom seeds any unset color from the wells' displayed
        // fallbacks, so the waveform immediately matches what the wells show.
        AppSettings *settings = AppSettings.sharedInstance;
        if (!settings.waveformCustomPlayedColor) {
            settings.waveformCustomPlayedColor = _customPlayedWell.color;
        }
        if (!settings.waveformCustomUnplayedColor) {
            settings.waveformCustomUnplayedColor = _customUnplayedWell.color;
        }
    }
    _customColorsRow.hidden = !custom;
    [self.playerController applyWaveformTheme:identifier];
}

- (void)customColorChanged:(NSColorWell *)sender {
    if (sender == _customPlayedWell) {
        AppSettings.sharedInstance.waveformCustomPlayedColor = sender.color;
    } else {
        AppSettings.sharedInstance.waveformCustomUnplayedColor = sender.color;
    }
    [self.playerController refreshWaveformTheme];
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
