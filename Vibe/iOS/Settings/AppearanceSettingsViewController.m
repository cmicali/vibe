//
//  AppearanceSettingsViewController.m
//  Vibe (iOS)
//

#import "AppearanceSettingsViewController.h"

#import "AppSettings.h"
#import "PlaybackController.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

typedef NS_ENUM(NSInteger, VibeAppearanceSection) {
    VibeAppearanceSectionNowPlaying = 0,
    VibeAppearanceSectionWaveform,
    VibeAppearanceSectionCount,
};

typedef NS_ENUM(NSInteger, VibeNowPlayingRow) {
    VibeNowPlayingRowTimeDisplay = 0,
    VibeNowPlayingRowFileInfo,
    VibeNowPlayingRowShuffleRepeat,
    VibeNowPlayingRowCount,
};

typedef NS_ENUM(NSInteger, VibeWaveformRow) {
    VibeWaveformRowStyle = 0,
    VibeWaveformRowWidgetStyle,
    VibeWaveformRowTheme,
    VibeWaveformRowPlayheadLine,
    VibeWaveformRowCentered,
    VibeWaveformRowWidgetCentered,
    VibeWaveformRowCount,
};

// Not a cast of the BOOL: a row index is a screen position.
static const NSInteger kTimeRowTotal     = 0;
static const NSInteger kTimeRowRemaining = 1;

static NSString *const kValueCellIdentifier  = @"value";

@implementation AppearanceSettingsViewController {
    PlaybackController *_playback;
    // IDENTIFIERS, sorted by localized display name; a display name is never
    // a key.
    NSArray<NSString *> *_waveformStyles;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _playback = playback;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_MENU_VIEW_APPEARANCE;
    _waveformStyles = [[WaveformRendererRegistry availableIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[WaveformRendererRegistry displayNameForIdentifier:a]
                localizedStandardCompare:[WaveformRendererRegistry displayNameForIdentifier:b]];
    }];
}

// A picker writes without telling this screen.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

// Resolved, not the stored value: an unknown identifier draws as the default.
- (NSString *)currentWaveformStyle {
    return [WaveformRendererRegistry resolveStyleIdentifier:AppSettings.sharedInstance.waveformStyle];
}

- (NSString *)waveformStyleValueText {
    return [WaveformRendererRegistry displayNameForIdentifier:[self currentWaveformStyle]];
}

// Match app reads as itself, NOT the app's style name, which would say the widget
// is pinned when it is following.
- (NSString *)widgetWaveformStyleValueText {
    NSString *identifier = AppSettings.sharedInstance.widgetWaveformStyle;
    return identifier ? [WaveformRendererRegistry displayNameForIdentifier:identifier]
                      : STR_SETTINGS_WIDGET_WAVEFORM_MATCH;
}

- (NSString *)timeDisplayValueText {
    return AppSettings.sharedInstance.showRemainingTime ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeAppearanceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == VibeAppearanceSectionNowPlaying ? (NSInteger)VibeNowPlayingRowCount
                                                       : (NSInteger)VibeWaveformRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == VibeAppearanceSectionNowPlaying ? STR_SETTINGS_NOW_PLAYING_SECTION
                                                       : STR_SETTINGS_WAVEFORM_SECTION;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL nowPlaying = indexPath.section == VibeAppearanceSectionNowPlaying;
    if (nowPlaying && indexPath.row == VibeNowPlayingRowFileInfo) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_FILE_INFO
                                                                on:AppSettings.sharedInstance.showFileInfo
                                                            target:self action:@selector(fileInfoToggled:)];
    }
    if (nowPlaying && indexPath.row == VibeNowPlayingRowShuffleRepeat) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_SHUFFLE_REPEAT
                                                                on:AppSettings.sharedInstance.showShuffleRepeat
                                                            target:self action:@selector(shuffleRepeatToggled:)];
    }
    if (!nowPlaying && indexPath.row == VibeWaveformRowPlayheadLine) {
        // The style's default until chosen, so it follows a style pick.
        BOOL line = [WaveformRendererRegistry
                drawsPlayheadLineForIdentifier:[self currentWaveformStyle]
                                        chosen:AppSettings.sharedInstance.waveformPlayheadLine];
        return [SettingsChoiceViewController switchCellInTableView:tableView
                                                             title:STR_SETTINGS_WAVEFORM_PLAYHEAD_LINE
                                                                on:line
                                                            target:self action:@selector(playheadLineToggled:)];
    }
    if (!nowPlaying && indexPath.row == VibeWaveformRowCentered) {
        UITableViewCell *cell = [SettingsChoiceViewController switchCellInTableView:tableView
                title:STR_SETTINGS_WAVEFORM_CENTERED on:AppSettings.sharedInstance.waveformCentered
                target:self action:@selector(centeredToggled:)];
        ((UISwitch *)cell.accessoryView).enabled =
                [WaveformRendererRegistry supportsCenteringForIdentifier:[self currentWaveformStyle]];
        return cell;
    }
    if (!nowPlaying && indexPath.row == VibeWaveformRowWidgetCentered) {
        // Under Match app the widget reads the card's, shown here, not its own.
        NSString *widgetStyle = AppSettings.sharedInstance.widgetWaveformStyle;
        UITableViewCell *cell = [SettingsChoiceViewController switchCellInTableView:tableView
                title:STR_SETTINGS_WIDGET_WAVEFORM_CENTERED on:AppSettings.sharedInstance.widgetWaveformCentered
                target:self action:@selector(widgetCenteredToggled:)];
        ((UISwitch *)cell.accessoryView).enabled = widgetStyle && [WaveformRendererRegistry
                supportsCenteringForIdentifier:[WaveformRendererRegistry resolveStyleIdentifier:widgetStyle]];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    if (nowPlaying) {
        content.text = STR_SETTINGS_SECTION_TIME;
        content.secondaryText = [self timeDisplayValueText];
    }
    else {
        switch ((VibeWaveformRow)indexPath.row) {
            case VibeWaveformRowStyle:
                content.text = STR_SETTINGS_THEME_WAVEFORM_STYLE;
                content.secondaryText = [self waveformStyleValueText];
                break;
            case VibeWaveformRowWidgetStyle:
                content.text = STR_SETTINGS_SECTION_WIDGET_WAVEFORM;
                content.secondaryText = [self widgetWaveformStyleValueText];
                break;
            default:
                content.text = STR_SETTINGS_SECTION_WAVEFORM_THEME;
                content.secondaryText = [WaveformThemeSettingsViewController currentThemeDisplayName];
                break;
        }
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BOOL nowPlaying = indexPath.section == VibeAppearanceSectionNowPlaying;
    if (nowPlaying ? indexPath.row != VibeNowPlayingRowTimeDisplay
                   : indexPath.row >= VibeWaveformRowPlayheadLine) {
        return;     // the switch rows
    }
    UIViewController *next = nil;
    if (nowPlaying) {
        next = [self timeDisplayPicker];
    }
    else {
        switch ((VibeWaveformRow)indexPath.row) {
            case VibeWaveformRowStyle:
                next = [self waveformStylePicker];
                break;
            case VibeWaveformRowWidgetStyle:
                next = [self widgetWaveformStylePicker];
                break;
            default:
                next = [[WaveformThemeSettingsViewController alloc] init];
                break;
        }
    }
    [self.navigationController pushViewController:next animated:YES];
}

// In _waveformStyles' order, so a picker's row index maps back to it.
- (NSMutableArray<NSString *> *)waveformStyleNames {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:_waveformStyles.count];
    for (NSString *identifier in _waveformStyles) {
        [names addObject:[WaveformRendererRegistry displayNameForIdentifier:identifier]];
    }
    return names;
}

- (SettingsChoiceViewController *)waveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    NSArray<NSString *> *styles = _waveformStyles;
    NSInteger selected = (NSInteger)[styles indexOfObject:[self currentWaveformStyle]];
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_THEME_WAVEFORM_STYLE
                  choices:names
            selectedIndex:selected
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.waveformStyle = styles[(NSUInteger)index];
        VibeNotifyDisplaySettingsChanged();
    }];
}

// Match app first, so every other row is offset by one against the styles.
- (SettingsChoiceViewController *)widgetWaveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    [names insertObject:STR_SETTINGS_WIDGET_WAVEFORM_MATCH atIndex:0];
    NSArray<NSString *> *styles = _waveformStyles;
    NSString *current = AppSettings.sharedInstance.widgetWaveformStyle;
    NSInteger selected = 0;
    if (current) {
        NSUInteger index = [styles indexOfObject:current];
        // An unregistered style falls back to Match app's checkmark.
        selected = index == NSNotFound ? 0 : (NSInteger)index + 1;
    }
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_SECTION_WIDGET_WAVEFORM
                  choices:names
            selectedIndex:selected
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.widgetWaveformStyle =
                index == 0 ? nil : styles[(NSUInteger)index - 1];
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (SettingsChoiceViewController *)timeDisplayPicker {
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_SECTION_TIME
                  choices:@[STR_SETTINGS_TIME_TOTAL, STR_SETTINGS_TIME_REMAINING]
            selectedIndex:(AppSettings.sharedInstance.showRemainingTime ? kTimeRowRemaining : kTimeRowTotal)
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.showRemainingTime = index == kTimeRowRemaining;
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (void)fileInfoToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.showFileInfo = toggle.isOn;
    VibeNotifyDisplaySettingsChanged();
}

- (void)playheadLineToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.waveformPlayheadLine = toggle.isOn;
    VibeNotifyDisplaySettingsChanged();
}

- (void)centeredToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.waveformCentered = toggle.isOn;
    VibeNotifyDisplaySettingsChanged();
    // Under Match app the widget's row shows this one.
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:VibeWaveformRowWidgetCentered
                                                                 inSection:VibeAppearanceSectionWaveform]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)widgetCenteredToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.widgetWaveformCentered = toggle.isOn;
    VibeNotifyDisplaySettingsChanged();
}

- (void)shuffleRepeatToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.showShuffleRepeat = toggle.isOn;
    // Either way: hidden clears both modes and CarPlay's buttons, shown
    // brings the buttons back.
    [_playback applyTrackTransitionSettings];
    VibeNotifyDisplaySettingsChanged();
}

@end
