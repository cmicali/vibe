//
//  FilesSettingsViewController.m
//  Vibe (iOS)
//

#import "FilesSettingsViewController.h"

#import "AccountMirror.h"
#import "AccountRules.h"
#import "AppSettings.h"
#import "SettingsRules.h"
#import "SettingsChoiceViewController.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

// One section per account, in AccountMirror.mirrors order, then these.
typedef NS_ENUM(NSInteger, VibeFilesSection) {
    VibeFilesSectionFolderSort = 0,
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

// A linked account's rows (accountRowsForMirror:).
typedef NS_ENUM(NSInteger, VibeAccountRow) {
    VibeAccountRowAccount = 0,
    VibeAccountRowRemoveDownloads,
    VibeAccountRowMaximumSize,
    VibeAccountRowDisconnect,
};

@implementation FilesSettingsViewController {
    NSArray<AccountMirror *> *_mirrors;
    // What each account's downloads take, by its mirror's place in
    // _mirrors; -1 until measured.
    NSMutableArray<NSNumber *> *_downloadBytes;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _mirrors = AccountMirror.mirrors;
        _downloadBytes = [NSMutableArray arrayWithCapacity:_mirrors.count];
        for (NSUInteger i = 0; i < _mirrors.count; i++) {
            [_downloadBytes addObject:@(-1)];
        }
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (AccountMirror *mirror in _mirrors) {
        [self measureDownloadsOfMirror:mirror];
    }
}

- (void)measureDownloadsOfMirror:(AccountMirror *)mirror {
    if (!mirror.client.isLinked) {
        return;
    }
    __weak FilesSettingsViewController *weakSelf = self;
    [mirror measureDownloadsWithCompletion:^(long long bytes) {
        FilesSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !mirror.client.isLinked) {
            return;
        }
        [strongSelf showDownloadBytes:bytes ofMirror:mirror];
    }];
}

// The section: the row comes and goes with the downloads.
- (void)showDownloadBytes:(long long)bytes ofMirror:(AccountMirror *)mirror {
    NSUInteger index = [_mirrors indexOfObjectIdenticalTo:mirror];
    if (index == NSNotFound) {
        return;
    }
    _downloadBytes[index] = @(bytes);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:index]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_FILES_ACCOUNTS;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(accountDidChange:)
                                               name:VibeAccountDidChangeNotification
                                             object:nil];
    // A song playing behind this screen downloads while the size is shown.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(downloadsDidChange:)
                                               name:VibeAccountDownloadsDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// The mirror counted the downloads for its budget; no second walk.
- (void)downloadsDidChange:(NSNotification *)notification {
    if (![notification.object isKindOfClass:AccountMirror.class]) {
        return;
    }
    [self showDownloadBytes:[notification.userInfo[VibeAccountDownloadsBytesKey] longLongValue]
                   ofMirror:notification.object];
}

- (void)accountDidChange:(NSNotification *)notification {
    [_mirrors enumerateObjectsUsingBlock:^(AccountMirror *mirror, NSUInteger index, BOOL *stop) {
        if (mirror.client != notification.object) {
            return;
        }
        self->_downloadBytes[index] = @(-1);
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:index]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
        [self measureDownloadsOfMirror:mirror];
    }];
}

#pragma mark - Sections

// The account a section shows, nil for the sections after them.
- (AccountMirror *)mirrorInSection:(NSInteger)section {
    return section >= 0 && (NSUInteger)section < _mirrors.count ? _mirrors[(NSUInteger)section] : nil;
}

// The section's place among the fixed ones after the accounts.
- (VibeFilesSection)fixedSection:(NSInteger)section {
    return (VibeFilesSection)(section - (NSInteger)_mirrors.count);
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_mirrors.count + VibeFilesSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    AccountMirror *mirror = [self mirrorInSection:section];
    if (mirror) {
        return (NSInteger)[self accountRowsForMirror:mirror].count;
    }
    return [self fixedSection:section] == VibeFilesSectionPaste ? 1 : VibeFolderSortRowCount;
}

// An account's rows, top to bottom: Connect alone while unlinked; linked,
// the account, Remove Downloads while there is something to remove, Maximum
// Size, and Disconnect.
- (NSArray<NSNumber *> *)accountRowsForMirror:(AccountMirror *)mirror {
    if (!mirror.client.isLinked) {
        return @[@(VibeAccountRowAccount)];
    }
    NSUInteger index = [_mirrors indexOfObjectIdenticalTo:mirror];
    return _downloadBytes[index].longLongValue > 0
            ? @[@(VibeAccountRowAccount), @(VibeAccountRowRemoveDownloads), @(VibeAccountRowMaximumSize),
                @(VibeAccountRowDisconnect)]
            : @[@(VibeAccountRowAccount), @(VibeAccountRowMaximumSize), @(VibeAccountRowDisconnect)];
}

- (VibeAccountRow)accountRowAtIndexPath:(NSIndexPath *)indexPath mirror:(AccountMirror *)mirror {
    return (VibeAccountRow)[self accountRowsForMirror:mirror][(NSUInteger)indexPath.row].integerValue;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    AccountMirror *mirror = [self mirrorInSection:section];
    if (mirror) {
        return mirror.serviceName;
    }
    return [self fixedSection:section] == VibeFilesSectionFolderSort ? STR_SETTINGS_FOLDER_SORT_LABEL : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    AccountMirror *mirror = [self mirrorInSection:section];
    if (mirror) {
        return mirror.client.isLinked
                ? STR_SETTINGS_ACCOUNT_FOOTER_LINKED
                : [NSString stringWithFormat:STR_SETTINGS_ACCOUNT_FOOTER, mirror.serviceName, VibeAppName()];
    }
    return [self fixedSection:section] == VibeFilesSectionPaste ? STR_SETTINGS_ALLOW_PASTE_FOOTER : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AccountMirror *mirror = [self mirrorInSection:indexPath.section];
    if (mirror) {
        return [self accountCellForTableView:tableView indexPath:indexPath mirror:mirror];
    }
    if ([self fixedSection:indexPath.section] == VibeFilesSectionPaste) {
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

- (UITableViewCell *)accountCellForTableView:(UITableView *)tableView
                                   indexPath:(NSIndexPath *)indexPath
                                      mirror:(AccountMirror *)mirror {
    OAuthAccountClient *client = mirror.client;
    VibeAccountRow row = [self accountRowAtIndexPath:indexPath mirror:mirror];
    BOOL accountRow = client.isLinked && row == VibeAccountRowAccount;
    if (client.isLinked && row == VibeAccountRowMaximumSize) {
        return [self maximumSizeCellForTableView:tableView mirror:mirror];
    }
    NSString *identifier = accountRow ? kAccountCellIdentifier : kActionCellIdentifier;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    if (accountRow) {
        UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
        content.text = client.accountName ?: mirror.serviceName;
        content.secondaryText = STR_SETTINGS_ACCOUNT_CONNECTED;
        content.image = [UIImage systemImageNamed:@"person.crop.circle"];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    if (client.isLinked && row == VibeAccountRowRemoveDownloads) {
        NSUInteger index = [_mirrors indexOfObjectIdenticalTo:mirror];
        content.text = STR_SETTINGS_ACCOUNT_REMOVE_DOWNLOADS;
        content.textProperties.color = UIColor.tintColor;
        content.secondaryText = [NSByteCountFormatter stringFromByteCount:_downloadBytes[index].longLongValue
                                                               countStyle:NSByteCountFormatterCountStyleFile];
    }
    else if (client.isLinked) {
        content.text = STR_SETTINGS_ACCOUNT_DISCONNECT;
        content.textProperties.color = UIColor.systemRedColor;
    }
    else {
        content.text = [NSString stringWithFormat:STR_SETTINGS_ACCOUNT_CONNECT, mirror.serviceName];
        content.textProperties.color = UIColor.tintColor;
        content.image = [UIImage imageNamed:mirror.glyphName];
    }
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)maximumSizeCellForTableView:(UITableView *)tableView mirror:(AccountMirror *)mirror {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = STR_SETTINGS_ACCOUNT_MAXIMUM_SIZE;
    content.secondaryText = [self budgetTitles][(NSUInteger)[self currentBudgetIndexOfMirror:mirror]];
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Accounts

// In kVibeAccountDownloadBudgets order, so an index names the same size in
// both; the formatter writes the unit as the language does.
- (NSArray<NSString *> *)budgetTitles {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (size_t i = 0; i < kVibeAccountDownloadBudgetCount; i++) {
        [titles addObject:[NSByteCountFormatter stringFromByteCount:kVibeAccountDownloadBudgets[i]
                                                         countStyle:NSByteCountFormatterCountStyleFile]];
    }
    return titles;
}

- (NSInteger)currentBudgetIndexOfMirror:(AccountMirror *)mirror {
    return (NSInteger)VibeAccountDownloadBudgetIndex((NSInteger)mirror.downloadBudget);
}

// Saved, then applied: the mirror applies and never saves. The section
// reloads on its own: a smaller size posts the new total
// (downloadsDidChange:), and coming back re-measures.
- (SettingsChoiceViewController *)maximumSizePickerForMirror:(AccountMirror *)mirror {
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_ACCOUNT_MAXIMUM_SIZE
                  choices:[self budgetTitles]
            selectedIndex:[self currentBudgetIndexOfMirror:mirror]
                 onSelect:^(NSInteger index) {
        [NSUserDefaults.standardUserDefaults setInteger:kVibeAccountDownloadBudgets[index]
                                                 forKey:mirror.downloadBudgetKey];
        mirror.downloadBudget = kVibeAccountDownloadBudgets[index];
    }];
}

- (void)connectMirror:(AccountMirror *)mirror {
    __weak FilesSettingsViewController *weakSelf = self;
    [mirror.client signInWithPresentationAnchor:self.view.window completion:^(NSError *error) {
        FilesSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !error) {
            return;
        }
        LogWarn(@"%@: sign-in failed: %@", mirror.serviceName, error.localizedDescription);
        [strongSelf vibePresentAlertWithTitle:mirror.serviceName
                                      message:[NSString stringWithFormat:STR_SETTINGS_ACCOUNT_CONNECT_FAILED,
                                               mirror.serviceName]];
    }];
}

// Asks first: it deletes the downloads and stops a playlist in the account.
- (void)confirmDisconnectMirror:(AccountMirror *)mirror {
    NSString *service = mirror.serviceName;
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:STR_SETTINGS_ACCOUNT_DISCONNECT_TITLE,
                                                         service]
                                                message:[NSString stringWithFormat:STR_SETTINGS_ACCOUNT_DISCONNECT_MESSAGE,
                                                         service]
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_SETTINGS_ACCOUNT_DISCONNECT
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [mirror.client signOut];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AccountMirror *mirror = [self mirrorInSection:indexPath.section];
    if (mirror) {
        VibeAccountRow row = [self accountRowAtIndexPath:indexPath mirror:mirror];
        if (!mirror.client.isLinked) {
            [self connectMirror:mirror];
        }
        else if (row == VibeAccountRowRemoveDownloads) {
            // No confirmation: nothing leaves the service, and a song comes
            // back by playing it.
            [mirror removeDownloadsWithCompletion:^{}];
        }
        else if (row == VibeAccountRowMaximumSize) {
            [self.navigationController pushViewController:[self maximumSizePickerForMirror:mirror] animated:YES];
        }
        else if (row == VibeAccountRowDisconnect) {
            [self confirmDisconnectMirror:mirror];
        }
        return;
    }
    // No API reads the paste permission, so the row is always there.
    if ([self fixedSection:indexPath.section] == VibeFilesSectionPaste) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                         options:@{}
                               completionHandler:nil];
        return;
    }
    // Governs the next open, so nothing is notified.
    AppSettings.sharedInstance.folderOpenSort = FolderSortForRow(indexPath.row);
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.section]
             withRowAnimation:UITableViewRowAnimationNone];
}

@end
