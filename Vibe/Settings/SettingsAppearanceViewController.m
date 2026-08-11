//
//  SettingsAppearanceViewController.m
//  Vibe
//

#import "SettingsAppearanceViewController.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Menus.h"
#import "VibeStrings.h"

static const CGFloat kAppearancePaneHeight = 200;
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
        @[[NSTextField labelWithString:STR_SETTINGS_TIME_LABEL], timeRadios],
        @[[NSTextField labelWithString:STR_SETTINGS_KEY_NOTATION_LABEL], _keyNotationPopUp],
        @[NSGridCell.emptyContentView, _keyColorsCheckbox],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kAppearancePaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    NSString *style = Settings.windowAppearanceStyle;
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
    NSString *current = Settings.waveformStyle;
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

    BOOL remaining = Settings.showRemainingTime;
    _timeTotalRadio.state = remaining ? NSControlStateValueOff : NSControlStateValueOn;
    _timeRemainingRadio.state = remaining ? NSControlStateValueOn : NSControlStateValueOff;

    NSString *notation = Settings.keyNotation;
    for (NSMenuItem *item in _keyNotationPopUp.itemArray) {
        if ([item.representedObject isEqualToString:notation]) {
            [_keyNotationPopUp selectItem:item];
            break;
        }
    }
    _keyColorsCheckbox.state = Settings.keyColorsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)appearanceChanged:(id)sender {
    switch (_appearancePopUp.selectedTag) {
        case VibeAppearanceTagLight:
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
            break;
        case VibeAppearanceTagDark:
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK;
            break;
        default:
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT;
            break;
    }
    // A non-menu sender applies the stored setting without rewriting it.
    [self.playerController setAppearance:nil];
}

- (void)waveformStyleChanged:(id)sender {
    [self.playerController applyWaveformStyle:_waveformPopUp.selectedItem.representedObject];
}

- (void)timeDisplayChanged:(NSButton *)sender {
    Settings.showRemainingTime = (sender == _timeRemainingRadio);
    [self.playerController refreshTimeDisplay];
}

- (void)keyNotationChanged:(id)sender {
    Settings.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    [self.playerController refreshKeyDisplay];
}

- (void)toggleKeyColors:(id)sender {
    Settings.keyColorsEnabled = (_keyColorsCheckbox.state == NSControlStateValueOn);
    [self.playerController refreshKeyDisplay];
}

@end
