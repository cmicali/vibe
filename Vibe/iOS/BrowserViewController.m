//
//  BrowserViewController.m
//  Vibe (iOS)
//

#import "BrowserViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "DocumentTypes.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "NSURLUtil.h"
#import "PlayableExtensions.h"
#import "PlaybackController.h"
#import "SearchFolderStore.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeBrowserRootSection) {
    VibeBrowserRootSectionDropbox = 0,
    VibeBrowserRootSectionDevice,
    // Last: its footer needs the room a last section has.
    VibeBrowserRootSectionLocations,
    VibeBrowserRootSectionCount,
};

typedef NS_ENUM(NSInteger, VibeBrowserSection) {
    VibeBrowserSectionFolders = 0,
    VibeBrowserSectionFiles,
    VibeBrowserSectionCount,
};

static NSString *const kSourceCellIdentifier = @"source";
static NSString *const kActionCellIdentifier = @"action";
static NSString *const kItemCellIdentifier = @"item";

@interface BrowserViewController () <UIDocumentPickerDelegate>
@end

@implementation BrowserViewController {
    PlaybackController *_playback;
    NSURL *_directoryURL;
    BOOL _appending;

    // A directory's rows, sorted as the Files app sorts names, and which of
    // the files are Dropbox placeholders — found with the listing, off main.
    NSArray<NSURL *> *_folders;
    NSArray<NSURL *> *_files;
    NSSet<NSURL *> *_placeholders;
    // Stamped on each disk listing, so a slow one cannot overwrite a newer.
    uint64_t _listingGeneration;
    // The Dropbox folder this directory mirrors ("" for the root), nil
    // outside the mirror: listed from disk at once, then refreshed.
    NSString *_dropboxPath;
    BOOL _refreshing;
    NSError *_refreshError;

    // Which picker is up: a location grant, or a one-off pick.
    BOOL _pickingLocation;
    UIBarButtonItem *_playItem;
    UIBarButtonItem *_addSelectedItem;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback
                    directoryURL:(NSURL *)directoryURL
                       appending:(BOOL)appending {
    self = [super initWithStyle:directoryURL ? UITableViewStylePlain : UITableViewStyleInsetGrouped];
    if (self) {
        _playback = playback;
        _directoryURL = [directoryURL copy];
        _appending = appending;
        _folders = @[];
        _files = @[];
        _placeholders = [NSSet set];
        _dropboxPath = directoryURL ? [DropboxMirror.shared dropboxPathForURL:directoryURL] : nil;
    }
    return self;
}

- (BOOL)isRoot {
    return _directoryURL == nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.isRoot) {
        self.navigationItem.title = STR_TAB_FILES;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
        self.navigationController.navigationBar.prefersLargeTitles = YES;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(sourcesDidChange:)
                                                   name:VibeSearchFoldersDidChangeNotification
                                                 object:SearchFolderStore.shared];
    }
    else {
        self.navigationItem.title = [self titleForDirectory];
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        self.tableView.allowsMultipleSelectionDuringEditing = YES;
        _playItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:
                                                                    _appending ? @"text.badge.plus" : @"play.fill"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(openDirectory)];
        _playItem.accessibilityLabel = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : STR_MENU_CONTEXT_PLAY;
        _addSelectedItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"text.badge.plus"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(addSelected)];
        _addSelectedItem.accessibilityLabel = STR_MENU_CONTEXT_ADD_TO_PLAYLIST;
        [self refreshBarItems];
        if (_dropboxPath) {
            UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
            [refresh addTarget:self action:@selector(refreshFromDropbox) forControlEvents:UIControlEventValueChanged];
            self.refreshControl = refresh;
        }
    }
    // The add sheet is modal and needs its own way out.
    if (_appending && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                              target:self
                                                              action:@selector(dismissSheet)];
    }
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sourcesDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.isRoot) {
        [self.tableView reloadData];
        return;
    }
    [self reloadFromDisk];
    if (_dropboxPath) {
        [self refreshFromDropbox];
    }
}

- (NSString *)titleForDirectory {
    if ([_dropboxPath isEqualToString:@""]) {
        return VibeNotLocalized(@"Dropbox");
    }
    if ([_directoryURL.URLByStandardizingPath isEqual:SearchFolderStore.containerDocumentsURL.URLByStandardizingPath]) {
        return [NSString stringWithFormat:STR_BROWSER_ON_DEVICE, UIDevice.currentDevice.localizedModel];
    }
    return [NSFileManager.defaultManager displayNameAtPath:_directoryURL.path] ?: _directoryURL.lastPathComponent;
}

// The account went or came, or a location was granted or removed. A pushed
// Dropbox folder of a signed-out account has nothing left to show, so the
// stack goes back to the sources.
- (void)sourcesDidChange:(NSNotification *)notification {
    if (self.isRoot) {
        [self.tableView reloadData];
        return;
    }
    if (_dropboxPath && !DropboxMirror.shared.client.isLinked) {
        [self.navigationController popToRootViewControllerAnimated:NO];
    }
}

#pragma mark - A directory's contents

- (void)reloadFromDisk {
    uint64_t generation = ++_listingGeneration;
    NSURL *directory = _directoryURL;
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    __weak BrowserViewController *weakSelf = self;
    // Off main: a granted location can be a provider's folder, whose listing
    // is IPC that can take seconds.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:directory
              includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                   error:NULL] ?: @[];
        NSMutableArray<NSURL *> *folders = [NSMutableArray array];
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        NSMutableSet<NSURL *> *placeholders = [NSMutableSet set];
        for (NSURL *url in contents) {
            NSNumber *isDirectory = nil;
            [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
            if (isDirectory.boolValue) {
                [folders addObject:url];
            }
            else if ([playable containsObject:url.pathExtension.lowercaseString]) {
                [files addObject:url];
                if ([NSURLUtil isRemotePlaceholderFile:url]) {
                    [placeholders addObject:url];
                }
            }
        }
        NSComparator byName = ^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        };
        [folders sortUsingComparator:byName];
        [files sortUsingComparator:byName];
        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_listingGeneration) {
                return;
            }
            strongSelf->_folders = folders;
            strongSelf->_files = files;
            strongSelf->_placeholders = placeholders;
            if (!strongSelf.tableView.isEditing) {
                [strongSelf.tableView reloadData];
            }
            [strongSelf refreshEmptyState];
            [strongSelf refreshBarItems];
        });
    });
}

- (void)refreshFromDropbox {
    if (_refreshing) {
        return;
    }
    _refreshing = YES;
    [self refreshEmptyState];
    __weak BrowserViewController *weakSelf = self;
    [DropboxMirror.shared refreshDropboxFolder:_dropboxPath completion:^(NSURL *folderURL, NSError *error) {
        BrowserViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_refreshing = NO;
        strongSelf->_refreshError = error;
        [strongSelf.refreshControl endRefreshing];
        if (error) {
            LogWarn(@"Dropbox: could not list %@: %@", strongSelf->_directoryURL.lastPathComponent,
                    error.localizedDescription);
        }
        [strongSelf reloadFromDisk];
    }];
}

- (BOOL)isEmpty {
    return _folders.count == 0 && _files.count == 0;
}

- (void)refreshEmptyState {
    if (self.isRoot || !self.isEmpty) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    if (_refreshing) {
        self.contentUnavailableConfiguration = [UIContentUnavailableConfiguration loadingConfiguration];
        return;
    }
    UIContentUnavailableConfiguration *empty = [UIContentUnavailableConfiguration emptyConfiguration];
    if (_refreshError) {
        empty.image = [UIImage systemImageNamed:@"wifi.exclamationmark"];
        empty.text = STR_BROWSER_DROPBOX_UNAVAILABLE;
    }
    else {
        empty.image = [UIImage systemImageNamed:@"music.note"];
        empty.text = STR_ERROR_FOLDER_EMPTY;
    }
    self.contentUnavailableConfiguration = empty;
}

- (void)refreshBarItems {
    if (self.isRoot) {
        return;
    }
    if (self.tableView.isEditing) {
        _addSelectedItem.enabled = self.tableView.indexPathsForSelectedRows.count > 0;
        self.navigationItem.rightBarButtonItems = @[self.editButtonItem, _addSelectedItem];
        return;
    }
    // Absent, not disabled, with nothing to act on: the Playlist tab's rule.
    // A folder's listing is flat, so one holding only folders plays nothing.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    if (!self.isEmpty) {
        [items addObject:self.editButtonItem];
    }
    if (_files.count > 0) {
        [items addObject:_playItem];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self refreshBarItems];
}

- (NSURL *)itemAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSURL *> *items = indexPath.section == VibeBrowserSectionFolders ? _folders : _files;
    return (NSUInteger)indexPath.row < items.count ? items[(NSUInteger)indexPath.row] : nil;
}

#pragma mark - Opening

// Every open is one of PlaybackController's roads. A file opened alone
// becomes its folder with it selected (FolderSession), since the browser's
// sources are all roots an open covers.
- (void)openURLs:(NSArray<NSURL *> *)urls appending:(BOOL)appending {
    if (urls.count == 0) {
        return;
    }
    if (appending) {
        [_playback addURLs:urls];
    }
    else {
        [_playback openURLs:urls openInPlace:YES];
    }
    if (_appending) {
        [self dismissSheet];
    }
}

- (void)openDirectory {
    [self openURLs:@[_directoryURL] appending:_appending];
}

- (void)addSelected {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    // In row order, which is the order a reader of the list expects.
    NSArray<NSIndexPath *> *selected = [self.tableView.indexPathsForSelectedRows
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *indexPath in selected) {
        NSURL *url = [self itemAtIndexPath:indexPath];
        if (url) {
            [urls addObject:url];
        }
    }
    [self setEditing:NO animated:YES];
    [self openURLs:urls appending:YES];
}

- (void)dismissSheet {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)pushDirectory:(NSURL *)url {
    BrowserViewController *next = [[BrowserViewController alloc] initWithPlayback:_playback
                                                                     directoryURL:url
                                                                        appending:_appending];
    [self.navigationController pushViewController:next animated:YES];
}

- (void)favoriteFolder:(NSURL *)url {
    // A failed mint adds no row: one without a bookmark cannot be opened.
    [_playback bookmarkFolderURL:url completion:^(NSData *bookmark) {
        if (bookmark) {
            [FavoritesStore.shared addFolderURL:url bookmark:bookmark];
        }
    }];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.isRoot ? (NSInteger)VibeBrowserRootSectionCount : (NSInteger)VibeBrowserSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.isRoot) {
        return (NSInteger)(section == VibeBrowserSectionFolders ? _folders.count : _files.count);
    }
    switch ((VibeBrowserRootSection)section) {
        case VibeBrowserRootSectionLocations:
            // Plus Add Folder… and Browse Files….
            return (NSInteger)SearchFolderStore.shared.folderURLs.count + 2;
        default:
            return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.isRoot && section == VibeBrowserRootSectionLocations) {
        return STR_BROWSER_LOCATIONS;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.isRoot && section == VibeBrowserRootSectionLocations) {
        return [NSString stringWithFormat:STR_SETTINGS_SEARCH_FOLDERS_FOOTER, VibeAppName()];
    }
    return nil;
}

- (UITableViewCell *)cellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.isRoot ? [self sourceCellAtIndexPath:indexPath] : [self itemCellAtIndexPath:indexPath];
}

- (UITableViewCell *)itemCellAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self cellWithIdentifier:kItemCellIdentifier];
    NSURL *url = [self itemAtIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = url.lastPathComponent;
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    if (indexPath.section == VibeBrowserSectionFolders) {
        content.image = [UIImage systemImageNamed:@"folder"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else {
        content.image = [UIImage systemImageNamed:@"music.note"];
        // Not downloaded yet: the cloud says a tap waits on the network.
        if ([_placeholders containsObject:url]) {
            UIImageView *cloud = [[UIImageView alloc] initWithImage:
                    [UIImage systemImageNamed:@"icloud.and.arrow.down"]];
            cloud.tintColor = UIColor.tertiaryLabelColor;
            cell.accessoryView = cloud;
        }
    }
    cell.contentConfiguration = content;
    return cell;
}

- (UITableViewCell *)sourceCellAtIndexPath:(NSIndexPath *)indexPath {
    DropboxClient *dropbox = DropboxMirror.shared.client;
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    BOOL action = NO;
    switch ((VibeBrowserRootSection)indexPath.section) {
        case VibeBrowserRootSectionDropbox:
            content.image = [UIImage systemImageNamed:@"shippingbox"];
            if (dropbox.isLinked) {
                content.text = VibeNotLocalized(@"Dropbox");
                content.secondaryText = dropbox.accountName;
            }
            else {
                content.text = STR_SETTINGS_DROPBOX_CONNECT;
                action = YES;
            }
            break;
        case VibeBrowserRootSectionDevice:
            content.text = [NSString stringWithFormat:STR_BROWSER_ON_DEVICE, UIDevice.currentDevice.localizedModel];
            content.image = [UIImage systemImageNamed:
                    UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"];
            break;
        default: {
            NSUInteger count = SearchFolderStore.shared.folderURLs.count;
            NSUInteger row = (NSUInteger)indexPath.row;
            if (row < count) {
                content.text = [SearchFolderStore.shared displayNameForFolderAtIndex:row];
                content.image = [UIImage systemImageNamed:@"folder"];
            }
            else if (row == count) {
                content.text = STR_SETTINGS_SEARCH_FOLDERS_ADD;
                content.image = [UIImage systemImageNamed:@"folder.badge.plus"];
                action = YES;
            }
            else {
                content.text = STR_BROWSER_OTHER_FILES;
                content.image = [UIImage systemImageNamed:@"doc.badge.ellipsis"];
                action = YES;
            }
            break;
        }
    }
    UITableViewCell *cell = [self cellWithIdentifier:action ? kActionCellIdentifier : kSourceCellIdentifier];
    if (action) {
        content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        content.imageProperties.tintColor = self.view.tintColor ?: UIColor.systemBlueColor;
    }
    else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self refreshBarItems];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.isRoot) {
        [self selectSourceAtIndexPath:indexPath];
        return;
    }
    NSURL *url = [self itemAtIndexPath:indexPath];
    if (!url) {
        return;
    }
    if (indexPath.section == VibeBrowserSectionFolders) {
        [self pushDirectory:url];
    }
    else {
        [self openURLs:@[url] appending:_appending];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self refreshBarItems];
    }
}

- (void)selectSourceAtIndexPath:(NSIndexPath *)indexPath {
    switch ((VibeBrowserRootSection)indexPath.section) {
        case VibeBrowserRootSectionDropbox: {
            DropboxMirror *mirror = DropboxMirror.shared;
            if (mirror.client.isLinked && mirror.accountURL) {
                [self pushDirectory:mirror.accountURL];
            }
            else {
                [mirror.client signInWithPresentationAnchor:self.view.window completion:^(NSError *error) {
                    if (error) {
                        LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
                        [self showAlertWithTitle:VibeNotLocalized(@"Dropbox")
                                         message:STR_SETTINGS_DROPBOX_CONNECT_FAILED];
                    }
                }];
            }
            return;
        }
        case VibeBrowserRootSectionDevice:
            [self pushDirectory:SearchFolderStore.containerDocumentsURL];
            return;
        default: {
            NSArray<NSURL *> *locations = SearchFolderStore.shared.folderURLs;
            NSUInteger row = (NSUInteger)indexPath.row;
            if (row < locations.count) {
                [self pushDirectory:locations[row]];
            }
            else {
                [self presentPickerForLocation:row == locations.count];
            }
            return;
        }
    }
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Row actions

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.isRoot) {
        return YES;
    }
    return indexPath.section == VibeBrowserRootSectionLocations
            && (NSUInteger)indexPath.row < SearchFolderStore.shared.folderURLs.count;
}

// Root only: the system draws and localizes Delete, which forgets a location.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.isRoot ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isRoot && style == UITableViewCellEditingStyleDelete) {
        [SearchFolderStore.shared removeFolderAtIndex:(NSUInteger)indexPath.row];
    }
}

// A context menu is never the only road to Add.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSURL *url = self.isRoot ? nil : [self itemAtIndexPath:indexPath];
    if (!url) {
        return nil;
    }
    __weak BrowserViewController *weakSelf = self;
    UIContextualAction *add = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                              handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        [weakSelf openURLs:@[url] appending:YES];
        completion(YES);
    }];
    add.image = [UIImage systemImageNamed:@"text.badge.plus"];
    add.backgroundColor = self.view.tintColor;
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[add]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    NSURL *url = self.isRoot ? nil : [self itemAtIndexPath:indexPath];
    if (!url || tableView.isEditing) {
        return nil;
    }
    BOOL folder = indexPath.section == VibeBrowserSectionFolders;
    BOOL appendingSheet = _appending;
    __weak BrowserViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (!appendingSheet) {
            [items addObject:[UIAction actionWithTitle:STR_MENU_CONTEXT_PLAY
                                                 image:[UIImage systemImageNamed:@"play.fill"]
                                            identifier:nil
                                               handler:^(UIAction *action) {
                [weakSelf openURLs:@[url] appending:NO];
            }]];
        }
        [items addObject:[UIAction actionWithTitle:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                                             image:[UIImage systemImageNamed:@"text.badge.plus"]
                                        identifier:nil
                                           handler:^(UIAction *action) {
            [weakSelf openURLs:@[url] appending:YES];
        }]];
        if (folder && !appendingSheet && ![FavoritesStore.shared containsFolderURL:url]) {
            [items addObject:[UIAction actionWithTitle:[NSString stringWithFormat:STR_MENU_CONTEXT_ADD_FAVORITE,
                                                                                  VibeAppName()]
                                                 image:[UIImage systemImageNamed:@"star"]
                                            identifier:nil
                                               handler:^(UIAction *action) {
                [weakSelf favoriteFolder:url];
            }]];
        }
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

#pragma mark - The system pickers

// A location: one folder, granted for good (SearchFolderStore). Anything else:
// files and folders from anywhere, for one open.
- (void)presentPickerForLocation:(BOOL)location {
    NSArray<UTType *> *types = location
            ? @[UTTypeFolder]
            : [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    // asCopy:NO: the grant must be to the real items.
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = !location;
    picker.delegate = self;
    _pickingLocation = location;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!_pickingLocation) {
        [self openURLs:urls appending:_appending];
        return;
    }
    NSURL *url = urls.firstObject;
    if (url && ![SearchFolderStore.shared addFolderURL:url]) {
        // Silence would read as a failed pick.
        [self showAlertWithTitle:STR_BROWSER_LOCATIONS message:STR_SETTINGS_SEARCH_FOLDERS_COVERED];
    }
}

@end
