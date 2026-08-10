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

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_APPEARANCE_LABEL], _appearancePopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_WAVEFORM_LABEL], _waveformPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_TIME_LABEL], timeRadios],
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

    NSString *current = Settings.waveformStyle;
    for (NSMenuItem *item in _waveformPopUp.itemArray) {
        if ([item.representedObject isEqualToString:current]) {
            [_waveformPopUp selectItem:item];
            break;
        }
    }

    BOOL remaining = Settings.showRemainingTime;
    _timeTotalRadio.state = remaining ? NSControlStateValueOff : NSControlStateValueOn;
    _timeRemainingRadio.state = remaining ? NSControlStateValueOn : NSControlStateValueOff;
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

@end
