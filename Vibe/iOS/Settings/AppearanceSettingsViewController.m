//
//  AppearanceSettingsViewController.m
//  Vibe (iOS)
//
//  See AppearanceSettingsViewController.h.
//

#import "AppearanceSettingsViewController.h"

#import "AppSettings.h"
#import "PlayerDisplaySettings.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

typedef NS_ENUM(NSInteger, VibeAppearanceRow) {
    VibeAppearanceRowWaveformStyle = 0,
    VibeAppearanceRowWidgetWaveformStyle,
    VibeAppearanceRowWaveformTheme,
    VibeAppearanceRowTimeDisplay,
    VibeAppearanceRowFileInfo,
    VibeAppearanceRowCount,
};

// The time display's two answers, in the order the mac's radio pair reads.
// Deliberately not a cast of the BOOL: a row index is a screen position.
static const NSInteger kTimeRowTotal     = 0;
static const NSInteger kTimeRowRemaining = 1;

static NSString *const kValueCellIdentifier  = @"value";
static NSString *const kSwitchCellIdentifier = @"switch";

@implementation AppearanceSettingsViewController {
    // Style IDENTIFIERS, sorted by their localized display names so the list
    // reads alphabetically in whatever language it is drawn in. A display name
    // is never a key — see AudioWaveformRenderer.h.
    NSArray<NSString *> *_waveformStyles;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
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

// The value column is this screen's whole job, and a picker writes its setting
// without telling anyone here — so the rows are re-read on the way back rather
// than kept in step from the other side.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

// The style actually being drawn, not the raw stored value: an identifier from
// a later version, or a hand-edited one, renders as the default, and a
// checkmark on a row nothing draws would misreport the screen.
- (NSString *)currentWaveformStyle {
    return [WaveformRendererRegistry resolveStyleIdentifier:AppSettings.sharedInstance.waveformStyle];
}

- (NSString *)waveformStyleValueText {
    return [WaveformRendererRegistry displayNameForIdentifier:[self currentWaveformStyle]];
}

// Unset is the default and reads as Match app — NOT as the app's style name,
// which would say the widget is pinned to it when it is actually following.
- (NSString *)widgetWaveformStyleValueText {
    NSString *identifier = AppSettings.sharedInstance.widgetWaveformStyle;
    return identifier ? [WaveformRendererRegistry displayNameForIdentifier:identifier]
                      : STR_SETTINGS_WIDGET_WAVEFORM_MATCH;
}

- (NSString *)timeDisplayValueText {
    return VibeShowsRemainingTime() ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return VibeAppearanceRowCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeAppearanceRow)indexPath.row == VibeAppearanceRowFileInfo) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSwitchCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kSwitchCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = [[UISwitch alloc] init];
            [toggle addTarget:self action:@selector(fileInfoToggled:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
        content.text = STR_SETTINGS_FILE_INFO;
        cell.contentConfiguration = content;
        ((UISwitch *)cell.accessoryView).on = VibeShowsFileInfo();
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    switch ((VibeAppearanceRow)indexPath.row) {
        case VibeAppearanceRowWaveformStyle:
            content.text = STR_SETTINGS_SECTION_WAVEFORM;
            content.secondaryText = [self waveformStyleValueText];
            break;
        case VibeAppearanceRowWidgetWaveformStyle:
            content.text = STR_SETTINGS_SECTION_WIDGET_WAVEFORM;
            content.secondaryText = [self widgetWaveformStyleValueText];
            break;
        case VibeAppearanceRowWaveformTheme:
            content.text = STR_SETTINGS_SECTION_WAVEFORM_THEME;
            content.secondaryText = [WaveformThemeSettingsViewController currentThemeDisplayName];
            break;
        default:
            content.text = STR_SETTINGS_SECTION_TIME;
            content.secondaryText = [self timeDisplayValueText];
            break;
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    switch ((VibeAppearanceRow)indexPath.row) {
        case VibeAppearanceRowWaveformStyle:
            next = [self waveformStylePicker];
            break;
        case VibeAppearanceRowWidgetWaveformStyle:
            next = [self widgetWaveformStylePicker];
            break;
        case VibeAppearanceRowWaveformTheme:
            next = [[WaveformThemeSettingsViewController alloc] init];
            break;
        case VibeAppearanceRowTimeDisplay:
            next = [self timeDisplayPicker];
            break;
        default:
            return;     // the switch row's own control changes it
    }
    [self.navigationController pushViewController:next animated:YES];
}

// The picker is handed display names and hands back a row index; the identifier
// it stands for is resolved here, against the same sorted array the names came
// from, so the two cannot get out of step.
// The styles' localized names, in _waveformStyles' order — both pickers list
// the same styles and differ only in what precedes them.
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
            initWithTitle:STR_SETTINGS_SECTION_WAVEFORM
                  choices:names
            selectedIndex:selected
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.waveformStyle = styles[(NSUInteger)index];
        VibeNotifyDisplaySettingsChanged();
    }];
}

// The same list with Match app on the front, so row 0 is "follow" and every
// other row is offset by one against the style array. The offset is the whole
// mapping and it lives here, beside the array it indexes.
- (SettingsChoiceViewController *)widgetWaveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    [names insertObject:STR_SETTINGS_WIDGET_WAVEFORM_MATCH atIndex:0];
    NSArray<NSString *> *styles = _waveformStyles;
    NSString *current = AppSettings.sharedInstance.widgetWaveformStyle;
    NSInteger selected = 0;
    if (current) {
        NSUInteger index = [styles indexOfObject:current];
        // A style that is no longer registered falls back to Match app rather
        // than leaving the list with no checkmark at all.
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
            selectedIndex:(VibeShowsRemainingTime() ? kTimeRowRemaining : kTimeRowTotal)
                 onSelect:^(NSInteger index) {
        VibeSetShowsRemainingTime(index == kTimeRowRemaining);
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (void)fileInfoToggled:(UISwitch *)toggle {
    VibeSetShowsFileInfo(toggle.isOn);
    VibeNotifyDisplaySettingsChanged();
}

@end
