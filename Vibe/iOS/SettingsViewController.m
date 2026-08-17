//
//  SettingsViewController.m
//  Vibe (iOS)
//
//  See SettingsViewController.h.
//

#import "SettingsViewController.h"

#import "AppSettings.h"
#import "PlayerDisplaySettings.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"

typedef NS_ENUM(NSInteger, VibeSettingsSection) {
    VibeSettingsSectionWaveform = 0,
    VibeSettingsSectionTime,
    VibeSettingsSectionFileInfo,
    VibeSettingsSectionCount,
};

// The time section's two rows, in the order the mac's radio pair reads.
typedef NS_ENUM(NSInteger, VibeSettingsTimeRow) {
    VibeSettingsTimeRowTotal = 0,
    VibeSettingsTimeRowRemaining,
    VibeSettingsTimeRowCount,
};

static NSString *const kChoiceCellIdentifier = @"choice";
static NSString *const kSwitchCellIdentifier = @"switch";

@implementation SettingsViewController {
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
    self.title = STR_SETTINGS_TITLE;
    _waveformStyles = [[WaveformRendererRegistry availableIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[WaveformRendererRegistry displayNameForIdentifier:a]
                localizedStandardCompare:[WaveformRendererRegistry displayNameForIdentifier:b]];
    }];
}

// The style actually being drawn, not the raw stored value: an identifier from
// a later version, or a hand-edited one, renders as the default, and a
// checkmark on a row nothing draws would misreport the screen.
- (NSString *)currentWaveformStyle {
    return [WaveformRendererRegistry resolveStyleIdentifier:Settings.waveformStyle];
}

// One notification for all of them: the screens that draw these settings are
// elsewhere in the app — the now-playing card sits minimized behind this one —
// and re-read the lot rather than being told which moved.
- (void)notifyDisplaySettingsChanged {
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeDisplaySettingsDidChangeNotification object:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((VibeSettingsSection)section) {
        case VibeSettingsSectionWaveform:
            return (NSInteger)_waveformStyles.count;
        case VibeSettingsSectionTime:
            return VibeSettingsTimeRowCount;
        default:
            return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibeSettingsSection)section) {
        case VibeSettingsSectionWaveform:
            return STR_SETTINGS_SECTION_WAVEFORM;
        case VibeSettingsSectionTime:
            return STR_SETTINGS_SECTION_TIME;
        default:
            // The switch says what it does; a heading over one row would only
            // repeat it.
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionFileInfo) {
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

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    BOOL selected = NO;
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionWaveform) {
        NSString *identifier = _waveformStyles[(NSUInteger)indexPath.row];
        content.text = [WaveformRendererRegistry displayNameForIdentifier:identifier];
        selected = [identifier isEqualToString:[self currentWaveformStyle]];
    }
    else {
        BOOL remaining = indexPath.row == VibeSettingsTimeRowRemaining;
        content.text = remaining ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL;
        selected = remaining == VibeShowsRemainingTime();
    }
    cell.contentConfiguration = content;
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark
                                  : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch ((VibeSettingsSection)indexPath.section) {
        case VibeSettingsSectionWaveform:
            Settings.waveformStyle = _waveformStyles[(NSUInteger)indexPath.row];
            break;
        case VibeSettingsSectionTime:
            VibeSetShowsRemainingTime(indexPath.row == VibeSettingsTimeRowRemaining);
            break;
        default:
            return;     // the switch row's own control is what changes it
    }
    // The whole section, so the checkmark leaves the row it was on.
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.section]
             withRowAnimation:UITableViewRowAnimationNone];
    [self notifyDisplaySettingsChanged];
}

- (void)fileInfoToggled:(UISwitch *)toggle {
    VibeSetShowsFileInfo(toggle.isOn);
    [self notifyDisplaySettingsChanged];
}

@end
