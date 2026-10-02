//
//  FilesSettingsViewController.m
//  Vibe (iOS)
//

#import "FilesSettingsViewController.h"

#import "AppSettings.h"
#import "SettingsRules.h"
#import "DropboxMirror.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeFilesSection) {
    VibeFilesSectionDropbox = 0,
    VibeFilesSectionFolderSort,
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

// The linked account's rows, top to bottom. Remove Downloads is there only
// while something is downloaded (rowAtIndex:).
typedef NS_ENUM(NSInteger, VibeDropboxRow) {
    VibeDropboxRowAccount = 0,
    VibeDropboxRowRemoveDownloads,
    VibeDropboxRowDisconnect,
    VibeDropboxRowCount,
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
        strongSelf->_downloadBytes = bytes;
        // The section: the row comes and goes with the downloads.
        [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionDropbox]
                            withRowAnimation:UITableViewRowAnimationNone];
    }];
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
                                           selector:@selector(measureDownloads)
                                               name:VibeDropboxDownloadsDidChangeNotification
                                             object:DropboxMirror.shared];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
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
    if ((VibeFilesSection)section != VibeFilesSectionDropbox) {
        return VibeFolderSortRowCount;
    }
    if (!DropboxMirror.shared.client.isLinked) {
        return 1;
    }
    return _downloadBytes > 0 ? VibeDropboxRowCount : VibeDropboxRowCount - 1;
}

// Which of the linked rows a table row is: with nothing downloaded, Disconnect
// moves up into Remove Downloads' place.
- (VibeDropboxRow)dropboxRowAtIndex:(NSInteger)index {
    return index == VibeDropboxRowRemoveDownloads && _downloadBytes <= 0
            ? VibeDropboxRowDisconnect : (VibeDropboxRow)index;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (VibeFilesSection)section == VibeFilesSectionDropbox
            ? VibeNotLocalized(@"Dropbox") : STR_SETTINGS_SECTION_FOLDER_SORT;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return (VibeFilesSection)section == VibeFilesSectionDropbox
            ? [NSString stringWithFormat:STR_SETTINGS_DROPBOX_FOOTER, VibeAppName()] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionDropbox) {
        return [self dropboxCellForTableView:tableView indexPath:indexPath];
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
        content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        content.secondaryText = [NSByteCountFormatter stringFromByteCount:_downloadBytes
                                                               countStyle:NSByteCountFormatterCountStyleFile];
    }
    else if (client.isLinked) {
        content.text = STR_SETTINGS_DROPBOX_DISCONNECT;
        content.textProperties.color = UIColor.systemRedColor;
    }
    else {
        content.text = STR_SETTINGS_DROPBOX_CONNECT;
        content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        content.image = [UIImage imageNamed:@"dropbox-glyph"];
    }
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - Dropbox

- (void)connectDropbox {
    __weak FilesSettingsViewController *weakSelf = self;
    [DropboxMirror.shared.client signInWithPresentationAnchor:self.view.window
                                                   completion:^(NSError *error) {
        FilesSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !error) {
            return;
        }
        LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
        UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:VibeNotLocalized(@"Dropbox")
                                                    message:STR_SETTINGS_DROPBOX_CONNECT_FAILED
                                             preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
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
            __weak FilesSettingsViewController *weakSelf = self;
            [DropboxMirror.shared removeDownloadsWithCompletion:^{
                [weakSelf measureDownloads];
            }];
        }
        else if ([self dropboxRowAtIndex:indexPath.row] == VibeDropboxRowDisconnect) {
            [self confirmDisconnectDropbox];
        }
        return;
    }
    // Governs the next open, so nothing is notified.
    AppSettings.sharedInstance.folderOpenSort = FolderSortForRow(indexPath.row);
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionFolderSort]
             withRowAnimation:UITableViewRowAnimationNone];
}

@end
