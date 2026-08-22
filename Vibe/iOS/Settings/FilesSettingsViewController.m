//
//  FilesSettingsViewController.m
//  Vibe (iOS)
//
//  See FilesSettingsViewController.h.
//

#import "FilesSettingsViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AppSettings.h"
#import "SearchFolderStore.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeFilesSection) {
    VibeFilesSectionFolderSort = 0,
    // Last, and deliberately: its footer needs the room a last section has.
    VibeFilesSectionSearchFolders,
    VibeFilesSectionCount,
};

// The folder-open order's three choices, in the order the mac's popup lists
// them. Deliberately not cast to VibeFolderOpenSort: a row index is a screen
// position, and the mapping below is where the two meet.
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

static NSString *FolderSortDisplayNameForRow(NSInteger row) {
    switch ((VibeFolderSortRow)row) {
        case VibeFolderSortRowNewestFirst: return STR_SETTINGS_FOLDER_SORT_NEWEST_FIRST;
        case VibeFolderSortRowAsReceived:  return STR_SETTINGS_FOLDER_SORT_AS_RECEIVED;
        default:                           return STR_SETTINGS_FOLDER_SORT_NAME;
    }
}

static NSString *const kChoiceCellIdentifier = @"choice";
static NSString *const kFolderCellIdentifier = @"folder";
static NSString *const kActionCellIdentifier = @"action";

@interface FilesSettingsViewController () <UIDocumentPickerDelegate>
@end

@implementation FilesSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_FILES;
    // Adds, removals and independently restored launch bookmarks all take this
    // one path, so the table's dynamic row count cannot drift from the store.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(searchFoldersDidChange:)
                                               name:VibeSearchFoldersDidChangeNotification
                                             object:SearchFolderStore.shared];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)searchFoldersDidChange:(NSNotification *)notification {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionSearchFolders]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeFilesSectionCount;
}

// The folder count, plus the Add row that is always last — so an empty list is
// still one tappable row rather than a section that draws as nothing.
- (NSInteger)folderRowCount {
    return (NSInteger)SearchFolderStore.shared.folderURLs.count + 1;
}

- (BOOL)isAddFolderRow:(NSIndexPath *)indexPath {
    return (VibeFilesSection)indexPath.section == VibeFilesSectionSearchFolders
            && indexPath.row == [self folderRowCount] - 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (VibeFilesSection)section == VibeFilesSectionSearchFolders ? [self folderRowCount]
                                                                     : VibeFolderSortRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (VibeFilesSection)section == VibeFilesSectionSearchFolders
            ? STR_SETTINGS_SECTION_SEARCH_FOLDERS : STR_SETTINGS_SECTION_FOLDER_SORT;
}

// The only footer on the screen, and it is load-bearing: without it an empty
// list reads as a feature that does not work, rather than as one waiting to be
// given a folder.
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return (VibeFilesSection)section == VibeFilesSectionSearchFolders
            ? [NSString stringWithFormat:STR_SETTINGS_SEARCH_FOLDERS_FOOTER, VibeAppName()]
            : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionSearchFolders) {
        return [self folderCellForTableView:tableView indexPath:indexPath];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = FolderSortDisplayNameForRow(indexPath.row);
    cell.contentConfiguration = content;
    cell.accessoryType = FolderSortForRow(indexPath.row) == AppSettings.sharedInstance.folderOpenSort
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
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
    return (VibeFilesSection)indexPath.section == VibeFilesSectionSearchFolders
            && ![self isAddFolderRow:indexPath];
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) {
        return;
    }
    [SearchFolderStore.shared removeFolderAtIndex:(NSUInteger)indexPath.row];
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
    }
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
    if ((VibeFilesSection)indexPath.section == VibeFilesSectionSearchFolders) {
        // A folder row is not a choice and not an open — the list is search
        // scope. Only the Add row does anything.
        if ([self isAddFolderRow:indexPath]) {
            [self presentFolderPicker];
        }
        return;
    }
    // Nothing on screen draws from it — the order governs the next folder open
    // — so the checkmark moves and nothing is notified.
    AppSettings.sharedInstance.folderOpenSort = FolderSortForRow(indexPath.row);
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeFilesSectionFolderSort]
             withRowAnimation:UITableViewRowAnimationNone];
}

@end
