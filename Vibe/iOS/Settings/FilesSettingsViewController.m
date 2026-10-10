//
//  FilesSettingsViewController.m
//  Vibe (iOS)
//

#import "FilesSettingsViewController.h"

#import "AppSettings.h"
#import "BrowserViewController.h"
#import "SettingsRules.h"
#import "DropboxMirror.h"
#import "DropboxRules.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeFilesSection) {
    VibeFilesSectionDropbox = 0,
    VibeFilesSectionFolderSort,
    // One row, which opens this app's page in the Settings app.
    VibeFilesSectionPaste,
    VibeFilesSectionCount,
};

// Not a cast of VibeFolderOpenSort: a row index is a screen position.
typedef NS_ENUM(NSInteger, VibeFolderSortRow) {
    VibeFolderSortRowName = 0,
    VibeFolderSortRowNewestFirst,
    VibeFolderSortRowAsReceived,
    VibeFolderSortRowCount,
};

static VibeFolderOpenSort FolderSortForRow(NSInteger row) {
    switch ((VibeFolderSortRow)row) {
        case VibeFolderSortRowNewestFirst: return VibeFolderOpenSortNewestFirst;
        case VibeFolderSortRowAsReceived:  return VibeFolderOpenSortAsReceived;
        default:                           return VibeFolderOpenSortName;
    }
}

static NSString *const kChoiceCellIdentifier = @"choice";
static NSString *const kActionCellIdentifier = @"action";
static NSString *const kAccountCellIdentifier = @"account";
static NSString *const kValueCellIdentifier = @"value";

// The linked account's rows (dropboxRows).
typedef NS_ENUM(NSInteger, VibeDropboxRow) {
    VibeDropboxRowAccount = 0,
    VibeDropboxRowRemoveDownloads,
    VibeDropboxRowMaximumSize,
    VibeDropboxRowDisconnect,
};

@implementation FilesSettingsViewController {
    // What the downloads take; -1 until measured.
    long long _downloadBytes;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _downloadBytes = -1;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self measureDownloads];
}

- (void)measureDownloads {
    if (!DropboxMirror.shared.client.isLinked) {
        return;
    }
    __weak FilesSettingsViewController *weakSelf = self;
    [DropboxMirror.shared measureDownloadsWithCompletion:^(long long bytes) {
        FilesSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !DropboxMirror.shared.client.isLinked) {
            return;
        }
        [strongSelf showDownloadBytes:bytes];
    }];
}

// The section: the row comes and goes with the downloads.
- (void)showDownloadBytes:(long long)bytes {
    _downloadBytes = bytes;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionDropbox]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_FILES_DROPBOX;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(dropboxAccountDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
    // A song playing behind this screen downloads while the size is shown.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(downloadsDidChange:)
                                               name:VibeDropboxDownloadsDidChangeNotification
                                             object:DropboxMirror.shared];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// The mirror counted the downloads for its budget; no second walk.
- (void)downloadsDidChange:(NSNotification *)notification {
    [self showDownloadBytes:[notification.userInfo[VibeDropboxDownloadsBytesKey] longLongValue]];
}

- (void)dropboxAccountDidChange:(NSNotification *)notification {
    _downloadBytes = -1;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionDropbox]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    [self measureDownloads];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeFilesSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((VibeFilesSection)section) {
        case VibeFilesSectionDropbox: return (NSInteger)[self dropboxRows].count;
        case VibeFilesSectionPaste:   return 1;
        default:                      return VibeFolderSortRowCount;
    }
}

// The Dropbox section's rows, top to bottom: Connect alone while unlinked;
// linked, the account, Remove Downloads while there is something to remove,
// Maximum Size, and Disconnect.
- (NSArray<NSNumber *> *)dropboxRows {
    if (!DropboxMirror.shared.client.isLinked) {
        return @[@(VibeDropboxRowAccount)];
    }
    return _downloadBytes > 0
            ? @[@(VibeDropboxRowAccount), @(VibeDropboxRowRemoveDownloads), @(VibeDropboxRowMaximumSize),
                @(VibeDropboxRowDisconnect)]
            : @[@(VibeDropboxRowAccount), @(VibeDropboxRowMaximumSize), @(VibeDropboxRowDisconnect)];
}

- (VibeDropboxRow)dropboxRowAtIndex:(NSInteger)index {
    return (VibeDropboxRow)[self dropboxRows][(NSUInteger)index].integerValue;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibeFilesSection)section) {
        case VibeFilesSectionDropbox:    return VibeNotLocalized(@"Dropbox");
        case VibeFilesSectionFolderSort: return STR_SETTINGS_FOLDER_SORT_LABEL;
        default:                         return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ((VibeFilesSection)section == VibeFilesSectionPaste) {
        return STR_SETTINGS_ALLOW_PASTE_FOOTER;
    }
    if ((VibeFilesSection)section != VibeFilesSectionDropbox) {
        return nil;
    }
    return DropboxMirror.shared.client.isLinked ? STR_SETTINGS_DROPBOX_FOOTER_LINKED
                                                : [NSString stringWithFormat:STR_SETTINGS_DROPBOX_FOOTER, VibeAppName()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionDropbox) {
        return [self dropboxCellForTableView:tableView indexPath:indexPath];
    }
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionPaste) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kActionCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kActionCellIdentifier];
        }
        UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
        content.text = STR_SETTINGS_ALLOW_PASTE;
        content.textProperties.color = UIColor.tintColor;
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = VibeFolderOpenSortDisplayName(FolderSortForRow(indexPath.row));
    cell.contentConfiguration = content;
    cell.accessoryType = FolderSortForRow(indexPath.row) == AppSettings.sharedInstance.folderOpenSort
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)dropboxCellForTableView:(UITableView *)tableView
                                   indexPath:(NSIndexPath *)indexPath {
    DropboxClient *client = DropboxMirror.shared.client;
    BOOL accountRow = client.isLinked && indexPath.row == VibeDropboxRowAccount;
    if (client.isLinked && [self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowMaximumSize) {
        return [self maximumSizeCellForTableView:tableView];
    }
    NSString *identifier = accountRow ? kAccountCellIdentifier : kActionCellIdentifier;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    if (accountRow) {
        UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
        content.text = client.accountName ?: VibeNotLocalized(@"Dropbox");
        content.secondaryText = STR_SETTINGS_DROPBOX_CONNECTED;
        content.image = [UIImage systemImageNamed:@"person.crop.circle"];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    if (client.isLinked && [self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowRemoveDownloads) {
        content.text = STR_SETTINGS_DROPBOX_REMOVE_DOWNLOADS;
        content.textProperties.color = UIColor.tintColor;
        content.secondaryText = [NSByteCountFormatter stringFromByteCount:_downloadBytes
                                                               countStyle:NSByteCountFormatterCountStyleFile];
    }
    else if (client.isLinked) {
        content.text = STR_SETTINGS_DROPBOX_DISCONNECT;
        content.textProperties.color = UIColor.systemRedColor;
    }
    else {
        content.text = STR_SETTINGS_DROPBOX_CONNECT;
        content.textProperties.color = UIColor.tintColor;
        content.image = [UIImage imageNamed:@"dropbox-glyph"];
    }
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)maximumSizeCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = STR_SETTINGS_DROPBOX_MAXIMUM_SIZE;
    content.secondaryText = [self budgetTitles][(NSUInteger)[self currentBudgetIndex]];
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Dropbox

// In kVibeDropboxDownloadBudgets order, so an index names the same size in
// both; the formatter writes the unit as the language does.
- (NSArray<NSString *> *)budgetTitles {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (size_t i = 0; i < kVibeDropboxDownloadBudgetCount; i++) {
        [titles addObject:[NSByteCountFormatter stringFromByteCount:kVibeDropboxDownloadBudgets[i]
                                                         countStyle:NSByteCountFormatterCountStyleFile]];
    }
    return titles;
}

- (NSInteger)currentBudgetIndex {
    return (NSInteger)VibeDropboxDownloadBudgetIndex((NSInteger)DropboxMirror.shared.downloadBudget);
}

// Saved, then applied: the mirror applies and never saves. The section
// reloads on its own: a smaller size posts the new total
// (downloadsDidChange:), and coming back re-measures.
- (SettingsChoiceViewController *)maximumSizePicker {
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_DROPBOX_MAXIMUM_SIZE
                  choices:[self budgetTitles]
            selectedIndex:[self currentBudgetIndex]
                 onSelect:^(NSInteger index) {
        [NSUserDefaults.standardUserDefaults setInteger:kVibeDropboxDownloadBudgets[index]
                                                 forKey:VibeDropboxDownloadBudgetKey];
        DropboxMirror.shared.downloadBudget = kVibeDropboxDownloadBudgets[index];
    }];
}

- (void)connectDropbox {
    __weak FilesSettingsViewController *weakSelf = self;
    [DropboxMirror.shared.client signInWithPresentationAnchor:self.view.window
                                                   completion:^(NSError *error) {
        FilesSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !error) {
            return;
        }
        LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
        VibePresentAlert(strongSelf, VibeNotLocalized(@"Dropbox"), STR_SETTINGS_DROPBOX_CONNECT_FAILED);
    }];
}

// Asks first: it deletes the downloads and stops a Dropbox playlist.
- (void)confirmDisconnectDropbox {
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:STR_SETTINGS_DROPBOX_DISCONNECT_TITLE
                                                message:STR_SETTINGS_DROPBOX_DISCONNECT_MESSAGE
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_SETTINGS_DROPBOX_DISCONNECT
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [DropboxMirror.shared.client signOut];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionDropbox) {
        if (!DropboxMirror.shared.client.isLinked) {
            [self connectDropbox];
        }
        else if ([self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowRemoveDownloads) {
            // No confirmation: nothing leaves Dropbox, and a song comes back
            // by playing it.
            [DropboxMirror.shared removeDownloadsWithCompletion:^{}];
        }
        else if ([self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowMaximumSize) {
            [self.navigationController pushViewController:[self maximumSizePicker] animated:YES];
        }
        else if ([self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowDisconnect) {
            [self confirmDisconnectDropbox];
        }
        return;
    }
    // No API reads the paste permission, so the row is always there.
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionPaste) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                         options:@{}
                               completionHandler:nil];
        return;
    }
    // Governs the next open, so nothing is notified.
    AppSettings.sharedInstance.folderOpenSort = FolderSortForRow(indexPath.row);
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionFolderSort]
             withRowAnimation:UITableViewRowAnimationNone];
}

@end
