//
//  AppearanceSettingsViewController.m
//  Vibe (iOS)
//

#import "AppearanceSettingsViewController.h"

#import "AppSettings.h"
#import "PlaybackController.h"
#import "SettingsChoiceViewController.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

// Time display is two checkmarked choices in place, a small set needs no
// pushed screen.
typedef NS_ENUM(NSInteger, VibeAppearanceSection) {
    VibeAppearanceSectionTimeDisplay = 0,
    VibeAppearanceSectionNowPlaying,
    VibeAppearanceSectionWaveform,
    VibeAppearanceSectionWidget,
    VibeAppearanceSectionCount,
};

typedef NS_ENUM(NSInteger, VibeNowPlayingRow) {
    VibeNowPlayingRowFileInfo = 0,
    VibeNowPlayingRowShuffleRepeat,
    VibeNowPlayingRowCount,
};

// The Widget group's rows too. Which show is waveformRowsForWidget:'s.
typedef NS_ENUM(NSInteger, VibeWaveformRow) {
    VibeWaveformRowStyle = 0,
    VibeWaveformRowType,
    VibeWaveformRowTheme,
    VibeWaveformRowColoring,
    VibeWaveformRowPlayheadLine,
    VibeWaveformRowCentered,
};

// Not a cast of the BOOL: a row index is a screen position.
static const NSInteger kTimeRowRemaining = 1;
static const NSInteger kTimeRowCount     = 2;

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
    _waveformStyles = [[WaveformRendererRegistry styleIdentifiers]
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

// Top to bottom. Under Match app the widget's group is Style alone, since
// the widget then draws every setting of the card's. Type shows only for a
// style that has types, and Coloring only for Spectrum.
- (NSArray<NSNumber *> *)waveformRowsForWidget:(BOOL)widget {
    if (widget && !AppSettings.sharedInstance.widgetWaveformStyle) {
        return @[@(VibeWaveformRowStyle)];
    }
    NSString *style = [self currentWaveformStyleForWidget:widget];
    NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObject:@(VibeWaveformRowStyle)];
    if ([WaveformRendererRegistry typeIdentifiersForIdentifier:style].count > 0) {
        [rows addObject:@(VibeWaveformRowType)];
    }
    [rows addObject:@(VibeWaveformRowTheme)];
    if ([WaveformRendererRegistry paletteKindForIdentifier:style] == VibeWaveformPaletteKindSpectrum) {
        [rows addObject:@(VibeWaveformRowColoring)];
    }
    [rows addObjectsFromArray:@[@(VibeWaveformRowPlayheadLine), @(VibeWaveformRowCentered)]];
    return rows;
}

- (VibeWaveformRow)waveformRowAtIndex:(NSInteger)index widget:(BOOL)widget {
    return (VibeWaveformRow)[self waveformRowsForWidget:widget][(NSUInteger)index].integerValue;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeAppearanceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == VibeAppearanceSectionTimeDisplay) {
        return kTimeRowCount;
    }
    if (section == VibeAppearanceSectionNowPlaying) {
        return VibeNowPlayingRowCount;
    }
    return (NSInteger)[self waveformRowsForWidget:section == VibeAppearanceSectionWidget].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibeAppearanceSection)section) {
        case VibeAppearanceSectionTimeDisplay: return STR_SETTINGS_SECTION_TIME;
        case VibeAppearanceSectionNowPlaying: return STR_SETTINGS_NOW_PLAYING_SECTION;
        case VibeAppearanceSectionWidget:     return STR_SETTINGS_WIDGET_SECTION;
        default:                              return STR_SETTINGS_WAVEFORM_SECTION;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == VibeAppearanceSectionTimeDisplay) {
        BOOL remainingRow = indexPath.row == kTimeRowRemaining;
        return [SettingsChoiceViewController checkmarkCellInTableView:tableView
                                                                title:remainingRow ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL
                                                                image:nil
                                                              checked:remainingRow == AppSettings.sharedInstance.showRemainingTime];
    }
    BOOL nowPlaying = indexPath.section == VibeAppearanceSectionNowPlaying;
    // The Waveform and Widget groups share their rows; the widget's read and
    // write the widget's copies. A switch carries its section as its tag.
    BOOL widget = indexPath.section == VibeAppearanceSectionWidget;
    VibeWaveformRow row = nowPlaying ? VibeWaveformRowStyle : [self waveformRowAtIndex:indexPath.row widget:widget];
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
    if (!nowPlaying && row == VibeWaveformRowPlayheadLine) {
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
    if (!nowPlaying && row == VibeWaveformRowCentered) {
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
    if (row == VibeWaveformRowStyle) {
        content.text = STR_SETTINGS_THEME_WAVEFORM_STYLE;
        content.secondaryText = [self waveformStyleValueTextForWidget:widget];
    }
    else if (row == VibeWaveformRowType) {
        content.text = STR_SETTINGS_WAVEFORM_TYPE;
        content.secondaryText = [WaveformRendererRegistry
                typeDisplayNameForIdentifier:[self currentWaveformStyleForWidget:widget]];
    }
    else if (row == VibeWaveformRowColoring) {
        content.text = STR_SETTINGS_WAVEFORM_SPECTRUM_COLORING;
        content.secondaryText = VibeWaveformSpectrumColoringDisplayName(
                [settings waveformSpectrumColoringForWidget:widget]);
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
        case VibeAppearanceSectionTimeDisplay: {
            BOOL remaining = indexPath.row == kTimeRowRemaining;
            if (remaining != AppSettings.sharedInstance.showRemainingTime) {
                AppSettings.sharedInstance.showRemainingTime = remaining;
                VibeNotifyDisplaySettingsChanged();
                // The whole section, so the checkmark leaves the row it was on.
                [tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeAppearanceSectionTimeDisplay]
                         withRowAnimation:UITableViewRowAnimationNone];
            }
            break;
        }
        case VibeAppearanceSectionNowPlaying:
            break;
        default: {
            VibeWaveformRow row = [self waveformRowAtIndex:indexPath.row widget:widget];
            next = row == VibeWaveformRowStyle ? (widget ? [self widgetWaveformStylePicker] : [self waveformStylePicker])
                 : row == VibeWaveformRowType ? [self waveformTypePickerForWidget:widget]
                 : row == VibeWaveformRowTheme ? [[WaveformThemeSettingsViewController alloc] initForWidget:widget]
                 : row == VibeWaveformRowColoring ? [self spectrumColoringPickerForWidget:widget]
                 : nil;
            break;
        }
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

// Detailed's types share its row, so rechoosing it keeps the type: the
// chooser ignores a tap on the checked row.
- (SettingsChoiceViewController *)waveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    NSArray<NSString *> *styles = _waveformStyles;
    NSString *current = [WaveformRendererRegistry styleIdentifierForIdentifier:[self currentWaveformStyleForWidget:NO]];
    NSInteger selected = (NSInteger)[styles indexOfObject:current];
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
    NSString *stored = AppSettings.sharedInstance.widgetWaveformStyle;
    NSString *current = stored ? [WaveformRendererRegistry styleIdentifierForIdentifier:stored] : nil;
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

// Reached only while the widget's style is its own, so a widget write lands
// in the widget's style.
- (SettingsChoiceViewController *)waveformTypePickerForWidget:(BOOL)widget {
    NSString *current = [self currentWaveformStyleForWidget:widget];
    NSArray<NSString *> *types = [WaveformRendererRegistry typeIdentifiersForIdentifier:current];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:types.count];
    for (NSString *type in types) {
        [names addObject:[WaveformRendererRegistry typeDisplayNameForIdentifier:type]];
    }
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_WAVEFORM_TYPE
                  choices:names
            selectedIndex:(NSInteger)[types indexOfObject:current]
                 onSelect:^(NSInteger index) {
        if (widget) {
            AppSettings.sharedInstance.widgetWaveformStyle = types[(NSUInteger)index];
        } else {
            AppSettings.sharedInstance.waveformStyle = types[(NSUInteger)index];
        }
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (SettingsChoiceViewController *)spectrumColoringPickerForWidget:(BOOL)widget {
    NSArray<NSString *> *colorings = VibeWaveformSpectrumColorings();
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:colorings.count];
    for (NSString *coloring in colorings) {
        [names addObject:VibeWaveformSpectrumColoringDisplayName(coloring)];
    }
    NSString *current = [AppSettings.sharedInstance waveformSpectrumColoringForWidget:widget];
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_WAVEFORM_SPECTRUM_COLORING
                  choices:names
            selectedIndex:(NSInteger)[colorings indexOfObject:current]
                 onSelect:^(NSInteger index) {
        [AppSettings.sharedInstance setWaveformSpectrumColoring:colorings[(NSUInteger)index] forWidget:widget];
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
