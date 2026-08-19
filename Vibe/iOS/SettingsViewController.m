//
//  SettingsViewController.m
//  Vibe (iOS)
//
//  See SettingsViewController.h.
//

#import "SettingsViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AppSettings.h"
#import "PlayerDisplaySettings.h"
#import "SearchFolderStore.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"

typedef NS_ENUM(NSInteger, VibeSettingsSection) {
    VibeSettingsSectionWaveform = 0,
    VibeSettingsSectionTime,
    VibeSettingsSectionFileInfo,
    // Last, and deliberately: everything above it is what the player draws,
    // where this grants the app access to a folder. Its footer needs the room a
    // last section has.
    VibeSettingsSectionSearchFolders,
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
static NSString *const kFolderCellIdentifier = @"folder";
static NSString *const kActionCellIdentifier = @"action";

@interface SettingsViewController () <UIDocumentPickerDelegate>
@end

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
    return [WaveformRendererRegistry resolveStyleIdentifier:AppSettings.sharedInstance.waveformStyle];
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

// The folder count, plus the Add row that is always last — so an empty list is
// still one tappable row rather than a section that draws as nothing.
- (NSInteger)folderRowCount {
    return (NSInteger)SearchFolderStore.shared.folderURLs.count + 1;
}

- (BOOL)isAddFolderRow:(NSIndexPath *)indexPath {
    return (VibeSettingsSection)indexPath.section == VibeSettingsSectionSearchFolders
            && indexPath.row == [self folderRowCount] - 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((VibeSettingsSection)section) {
        case VibeSettingsSectionWaveform:
            return (NSInteger)_waveformStyles.count;
        case VibeSettingsSectionTime:
            return VibeSettingsTimeRowCount;
        case VibeSettingsSectionSearchFolders:
            return [self folderRowCount];
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
        case VibeSettingsSectionSearchFolders:
            return STR_SETTINGS_SECTION_SEARCH_FOLDERS;
        default:
            // The switch says what it does; a heading over one row would only
            // repeat it.
            return nil;
    }
}

// The only footer on the screen, and it is load-bearing: without it an empty
// list reads as a feature that does not work, rather than as one waiting to be
// given a folder.
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return (VibeSettingsSection)section == VibeSettingsSectionSearchFolders
            ? STR_SETTINGS_SEARCH_FOLDERS_FOOTER : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionSearchFolders) {
        return [self folderCellForTableView:tableView indexPath:indexPath];
    }
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

- (UITableViewCell *)folderCellForTableView:(UITableView *)tableView
                                  indexPath:(NSIndexPath *)indexPath {
    BOOL isAdd = [self isAddFolderRow:indexPath];
    NSString *identifier = isAdd ? kActionCellIdentifier : kFolderCellIdentifier;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    if (isAdd) {
        content.text = STR_SETTINGS_SEARCH_FOLDERS_ADD;
        content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        content.image = [UIImage systemImageNamed:@"folder.badge.plus"];
    }
    else {
        content.text = [SearchFolderStore.shared
                displayNameForFolderAtIndex:(NSUInteger)indexPath.row];
        content.image = [UIImage systemImageNamed:@"folder"];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Search folders

// Swipe to delete, on the folders and never on the Add row. Removing one gives
// the grant up, so the footer's promise stays true.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (VibeSettingsSection)indexPath.section == VibeSettingsSectionSearchFolders
            && ![self isAddFolderRow:indexPath];
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) {
        return;
    }
    [SearchFolderStore.shared removeFolderAtIndex:(NSUInteger)indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

// Folders only — asCopy:NO, so the grant is to the real folder rather than to a
// copy in our container, which is the whole point.
- (void)presentFolderPicker {
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]
                                                                       asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }
    if (![SearchFolderStore.shared addFolderURL:url]) {
        // Silence would read as the pick having failed, when in fact there was
        // nothing to do — a grant already reaches inside this folder.
        [self showAlreadyCoveredAlert];
        return;
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeSettingsSectionSearchFolders]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)showAlreadyCoveredAlert {
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:STR_SETTINGS_SECTION_SEARCH_FOLDERS
                                                message:STR_SETTINGS_SEARCH_FOLDERS_COVERED
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch ((VibeSettingsSection)indexPath.section) {
        case VibeSettingsSectionWaveform:
            AppSettings.sharedInstance.waveformStyle = _waveformStyles[(NSUInteger)indexPath.row];
            break;
        case VibeSettingsSectionTime:
            VibeSetShowsRemainingTime(indexPath.row == VibeSettingsTimeRowRemaining);
            break;
        case VibeSettingsSectionSearchFolders:
            // A folder row is not a choice and not an open — the list is search
            // scope. Only the Add row does anything.
            if ([self isAddFolderRow:indexPath]) {
                [self presentFolderPicker];
            }
            return;     // no display setting moved, so nothing to notify
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
