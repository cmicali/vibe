//
//  AppearanceSettingsViewController.m
//  Vibe (iOS)
//
//  See AppearanceSettingsViewController.h.
//

#import "AppearanceSettingsViewController.h"

#import "AppSettings.h"
#import "Formatters.h"
#import "PlayerDisplaySettings.h"
#import "SettingsChoiceViewController.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

typedef NS_ENUM(NSInteger, VibeAppearanceRow) {
    VibeAppearanceRowWaveformStyle = 0,
    VibeAppearanceRowWaveformTheme,
    VibeAppearanceRowWaveformNormalize,
    VibeAppearanceRowWaveformGain,
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
static NSString *const kSliderCellIdentifier = @"slider";

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

// The stored value re-read through the half-dB ladder, so the number shown is
// the number kept — the mac readout's rule, and the same formatter, since a
// signed decimal is locale-dependent.
- (NSString *)waveformGainValueText {
    return [NSString stringWithFormat:STR_SETTINGS_WAVEFORM_GAIN_VALUE,
            [Formatters.sharedInstance signedDecimalString:AppSettings.sharedInstance.waveformGainDB]];
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
    if ((VibeAppearanceRow)indexPath.row == VibeAppearanceRowWaveformGain) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSliderCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kSliderCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 140, 30)];
            slider.minimumValue = (float)-kVibeWaveformGainMaxDB;
            slider.maximumValue = (float)kVibeWaveformGainMaxDB;
            [slider addTarget:self action:@selector(gainChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = slider;
        }
        UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
        content.text = STR_SETTINGS_WAVEFORM_GAIN;
        content.secondaryText = [self waveformGainValueText];
        cell.contentConfiguration = content;
        ((UISlider *)cell.accessoryView).value = (float)AppSettings.sharedInstance.waveformGainDB;
        return cell;
    }

    if ((VibeAppearanceRow)indexPath.row == VibeAppearanceRowFileInfo ||
        (VibeAppearanceRow)indexPath.row == VibeAppearanceRowWaveformNormalize) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSwitchCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kSwitchCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = [[UISwitch alloc] init];
            [toggle addTarget:self action:@selector(switchToggled:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        BOOL isFileInfo = ((VibeAppearanceRow)indexPath.row == VibeAppearanceRowFileInfo);
        UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
        content.text = isFileInfo ? STR_SETTINGS_FILE_INFO : STR_SETTINGS_WAVEFORM_NORMALIZE;
        cell.contentConfiguration = content;
        // The row the toggle stands for: one identifier serves both, so a
        // reused cell must be re-pointed rather than trusted.
        UISwitch *toggle = (UISwitch *)cell.accessoryView;
        toggle.tag = indexPath.row;
        toggle.on = isFileInfo ? VibeShowsFileInfo() : AppSettings.sharedInstance.waveformNormalize;
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
        case VibeAppearanceRowWaveformTheme:
            next = [[WaveformThemeSettingsViewController alloc] init];
            break;
        case VibeAppearanceRowTimeDisplay:
            next = [self timeDisplayPicker];
            break;
        default:
            return;     // the switch and slider rows' own controls change those
    }
    [self.navigationController pushViewController:next animated:YES];
}

// The picker is handed display names and hands back a row index; the identifier
// it stands for is resolved here, against the same sorted array the names came
// from, so the two cannot get out of step.
- (SettingsChoiceViewController *)waveformStylePicker {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:_waveformStyles.count];
    for (NSString *identifier in _waveformStyles) {
        [names addObject:[WaveformRendererRegistry displayNameForIdentifier:identifier]];
    }
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

- (void)switchToggled:(UISwitch *)toggle {
    if ((VibeAppearanceRow)toggle.tag == VibeAppearanceRowFileInfo) {
        VibeSetShowsFileInfo(toggle.isOn);
    } else {
        AppSettings.sharedInstance.waveformNormalize = toggle.isOn;
    }
    VibeNotifyDisplaySettingsChanged();
}

// Continuous, and deliberately not throttled here: the store lands every write
// on the half-dB ladder, so a drag writes the same value repeatedly between
// steps and the pages' syncWaveformLevels compares equal and does nothing.
// The readout is updated in place rather than by reloading the row, which
// would rebuild the cell under the finger holding the slider.
- (void)gainChanged:(UISlider *)slider {
    AppSettings.sharedInstance.waveformGainDB = slider.value;
    NSIndexPath *path = [NSIndexPath indexPathForRow:VibeAppearanceRowWaveformGain inSection:0];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if ([cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
        content.secondaryText = [self waveformGainValueText];
        cell.contentConfiguration = content;
    }
    VibeNotifyDisplaySettingsChanged();
}

@end
