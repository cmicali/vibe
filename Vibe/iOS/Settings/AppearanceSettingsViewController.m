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
    VibeAppearanceSectionWidget,
    VibeAppearanceSectionCount,
};

typedef NS_ENUM(NSInteger, VibeNowPlayingRow) {
    VibeNowPlayingRowTimeDisplay = 0,
    VibeNowPlayingRowFileInfo,
    VibeNowPlayingRowShuffleRepeat,
    VibeNowPlayingRowCount,
};

// The Widget group's rows too. Under Match app it shows only Style, since
// the widget then draws every setting of the card's.
typedef NS_ENUM(NSInteger, VibeWaveformRow) {
    VibeWaveformRowStyle = 0,
    VibeWaveformRowTheme,
    VibeWaveformRowPlayheadLine,
    VibeWaveformRowCentered,
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
// The widget's is the card's under Match app.
- (NSString *)currentWaveformStyleForWidget:(BOOL)widget {
    AppSettings *settings = AppSettings.sharedInstance;
    return [WaveformRendererRegistry resolveStyleIdentifier:(widget ? settings.widgetWaveformStyle : nil)
                                                            ?: settings.waveformStyle];
}

// Match app reads as itself, NOT the app's style name, which would say the widget
// is pinned when it is following.
- (NSString *)waveformStyleValueTextForWidget:(BOOL)widget {
    if (widget && !AppSettings.sharedInstance.widgetWaveformStyle) {
        return STR_SETTINGS_WIDGET_WAVEFORM_MATCH;
    }
    return [WaveformRendererRegistry displayNameForIdentifier:[self currentWaveformStyleForWidget:widget]];
}

- (NSString *)timeDisplayValueText {
    return AppSettings.sharedInstance.showRemainingTime ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeAppearanceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((VibeAppearanceSection)section) {
        case VibeAppearanceSectionNowPlaying: return VibeNowPlayingRowCount;
        case VibeAppearanceSectionWidget:     return AppSettings.sharedInstance.widgetWaveformStyle
                                                     ? VibeWaveformRowCount : VibeWaveformRowStyle + 1;
        default:                              return VibeWaveformRowCount;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibeAppearanceSection)section) {
        case VibeAppearanceSectionNowPlaying: return STR_SETTINGS_NOW_PLAYING_SECTION;
        case VibeAppearanceSectionWidget:     return STR_SETTINGS_WIDGET_SECTION;
        default:                              return STR_SETTINGS_WAVEFORM_SECTION;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL nowPlaying = indexPath.section == VibeAppearanceSectionNowPlaying;
    // The Waveform and Widget groups share their rows; the widget's read and
    // write the widget's copies. A switch carries its section as its tag.
    BOOL widget = indexPath.section == VibeAppearanceSectionWidget;
    AppSettings *settings = AppSettings.sharedInstance;
    if (nowPlaying && indexPath.row == VibeNowPlayingRowFileInfo) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_FILE_INFO
                                                                on:settings.showFileInfo
                                                            target:self action:@selector(fileInfoToggled:)];
    }
    if (nowPlaying && indexPath.row == VibeNowPlayingRowShuffleRepeat) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_SHUFFLE_REPEAT
                                                                on:settings.showShuffleRepeat
                                                            target:self action:@selector(shuffleRepeatToggled:)];
    }
    if (!nowPlaying && indexPath.row == VibeWaveformRowPlayheadLine) {
        // The style's default until chosen, so it follows a style pick.
        BOOL line = [WaveformRendererRegistry
                drawsPlayheadLineForIdentifier:[self currentWaveformStyleForWidget:widget]
                                        chosen:[settings waveformPlayheadLineForWidget:widget]];
        UITableViewCell *cell = [SettingsChoiceViewController switchCellInTableView:tableView
                                                                              title:STR_SETTINGS_WAVEFORM_PLAYHEAD_LINE
                                                                                 on:line
                                                                             target:self action:@selector(playheadLineToggled:)];
        cell.accessoryView.tag = indexPath.section;
        return cell;
    }
    if (!nowPlaying && indexPath.row == VibeWaveformRowCentered) {
        UITableViewCell *cell = [SettingsChoiceViewController switchCellInTableView:tableView
                title:STR_SETTINGS_WAVEFORM_CENTERED on:[settings waveformCenteredForWidget:widget]
                target:self action:@selector(centeredToggled:)];
        ((UISwitch *)cell.accessoryView).enabled =
                [WaveformRendererRegistry supportsCenteringForIdentifier:[self currentWaveformStyleForWidget:widget]];
        cell.accessoryView.tag = indexPath.section;
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
    else if (indexPath.row == VibeWaveformRowStyle) {
        content.text = STR_SETTINGS_THEME_WAVEFORM_STYLE;
        content.secondaryText = [self waveformStyleValueTextForWidget:widget];
    }
    else {
        content.text = STR_SETTINGS_SECTION_WAVEFORM_THEME;
        content.secondaryText = [WaveformThemeSettingsViewController currentThemeDisplayNameForWidget:widget];
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    BOOL widget = indexPath.section == VibeAppearanceSectionWidget;
    switch ((VibeAppearanceSection)indexPath.section) {
        case VibeAppearanceSectionNowPlaying:
            next = indexPath.row == VibeNowPlayingRowTimeDisplay ? [self timeDisplayPicker] : nil;
            break;
        default:
            next = indexPath.row == VibeWaveformRowStyle ? (widget ? [self widgetWaveformStylePicker] : [self waveformStylePicker])
                 : indexPath.row == VibeWaveformRowTheme ? [[WaveformThemeSettingsViewController alloc] initForWidget:widget]
                 : nil;
            break;
    }
    if (next) {
        [self.navigationController pushViewController:next animated:YES];
    }
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
    NSInteger selected = (NSInteger)[styles indexOfObject:[self currentWaveformStyleForWidget:NO]];
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
    [AppSettings.sharedInstance setWaveformPlayheadLine:toggle.isOn
                                              forWidget:toggle.tag == VibeAppearanceSectionWidget];
    VibeNotifyDisplaySettingsChanged();
}

- (void)centeredToggled:(UISwitch *)toggle {
    [AppSettings.sharedInstance setWaveformCentered:toggle.isOn
                                          forWidget:toggle.tag == VibeAppearanceSectionWidget];
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
