//
//  BrowserViewController.m
//  Vibe (iOS)
//

#import "BrowserViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AppSettings.h"
#import "DocumentTypes.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "PlayableExtensions.h"
#import "PlaybackController.h"
#import "PlaylistFile.h"
#import "SearchFolderStore.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeBrowserRootSection) {
    VibeBrowserRootSectionSources = 0,
    // Last: its footer needs the room a last section has.
    VibeBrowserRootSectionLocations,
    VibeBrowserRootSectionCount,
};

// The rows of the sources group.
typedef NS_ENUM(NSInteger, VibeBrowserSource) {
    VibeBrowserSourceDevice = 0,
    VibeBrowserSourceDropbox,
    VibeBrowserSourceRecents,
    VibeBrowserSourceCount,
};

typedef NS_ENUM(NSInteger, VibeBrowserSection) {
    VibeBrowserSectionFolders = 0,
    VibeBrowserSectionFiles,
    VibeBrowserSectionCount,
};

static NSString *const kSourceCellIdentifier = @"source";
static NSString *const kActionCellIdentifier = @"action";
static NSString *const kItemCellIdentifier = @"item";

// Going back to a folder relists it only this long after its last listing;
// pull to refresh always does.
static const CFTimeInterval kRelistInterval = 60;

@interface BrowserViewController () <UIDocumentPickerDelegate>
@end

// Every file and folder played or added, newest first (FolderSession). A file
// plays alone, as a search hit does; a folder opens as the playlist. Its own
// screen rather than a browser mode: it lists no directory, and every one of
// the browser's directory branches would need a third arm.
@interface RecentsViewController : UITableViewController
- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending;
@end

static void VibePresentAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void)) {
    return [UIAction actionWithTitle:title
                               image:[UIImage systemImageNamed:symbol]
                          identifier:nil
                             handler:^(UIAction *action) {
        handler();
    }];
}

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
    // When this screen last listed its folder from Dropbox; a reappearance
    // within kRelistInterval shows the disk alone.
    CFAbsoluteTime _listedAt;

    // Which picker is up: a location grant, or a one-off pick.
    BOOL _pickingLocation;
    UIBarButtonItem *_playItem;
    UIBarButtonItem *_addSelectedItem;
    UIBarButtonItem *_sortItem;
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
        _sortItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                      menu:[self sortMenu]];
        _sortItem.accessibilityLabel = STR_BROWSER_SORT;
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
    if (_dropboxPath && CFAbsoluteTimeGetCurrent() - _listedAt > kRelistInterval) {
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

// Sorted by the folder-open order, so a directory plays in the order it is
// shown; the sort menu sets that one setting.
- (void)reloadFromDisk {
    uint64_t generation = ++_listingGeneration;
    NSURL *directory = _directoryURL;
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    __weak BrowserViewController *weakSelf = self;
    // Off main: a granted location can be a provider's folder, whose listing
    // is IPC that can take seconds.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:directory
              includingPropertiesForKeys:[NSURLUtil listingKeysForSort:sort]
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
            else if ([playable containsObject:url.pathExtension.lowercaseString]
                    || [PlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
                [files addObject:url];
                if ([NSURLUtil isRemotePlaceholderFile:url]) {
                    [placeholders addObject:url];
                }
            }
        }
        [NSURLUtil sortURLs:folders by:sort];
        [NSURLUtil sortURLs:files by:sort];
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
        // A failed listing is tried again on the next appearance.
        strongSelf->_listedAt = error ? 0 : CFAbsoluteTimeGetCurrent();
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
    if (!self.isEmpty) {
        [items addObject:_sortItem];
    }
    self.navigationItem.rightBarButtonItems = items;
}

// Built when opened, so its check follows a change made on another screen.
- (UIMenu *)sortMenu {
    __weak BrowserViewController *weakSelf = self;
    UIDeferredMenuElement *choices = [UIDeferredMenuElement elementWithUncachedProvider:
            ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        VibeFolderOpenSort current = AppSettings.sharedInstance.folderOpenSort;
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (VibeFolderOpenSort sort = VibeFolderOpenSortName; sort <= VibeFolderOpenSortAsReceived; sort++) {
            UIAction *action = [UIAction actionWithTitle:VibeFolderOpenSortDisplayName(sort)
                                                   image:nil
                                              identifier:nil
                                                 handler:^(UIAction *a) {
                AppSettings.sharedInstance.folderOpenSort = sort;
                [weakSelf reloadFromDisk];
            }];
            action.state = sort == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        completion(actions);
    }];
    return [UIMenu menuWithChildren:@[choices]];
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

- (BrowserViewController *)browserForDirectory:(NSURL *)url {
    return [[BrowserViewController alloc] initWithPlayback:_playback directoryURL:url appending:_appending];
}

- (void)pushDirectory:(NSURL *)url {
    [self.navigationController pushViewController:[self browserForDirectory:url] animated:YES];
}

- (void)showDirectory:(NSURL *)directory {
    NSMutableArray<NSURL *> *sources = [NSMutableArray array];
    if (DropboxMirror.shared.accountURL) {
        [sources addObject:DropboxMirror.shared.accountURL];
    }
    [sources addObjectsFromArray:SearchFolderStore.shared.searchRoots];
    NSMutableArray<NSString *> *sourcePaths = [NSMutableArray arrayWithCapacity:sources.count];
    for (NSURL *source in sources) {
        [sourcePaths addObject:source.URLByStandardizingPath.path ?: @""];
    }
    NSURL *standardized = directory.URLByStandardizingPath;
    NSUInteger index = VibeSearchFolderCoveringRootIndex(sourcePaths, standardized.path);
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:self];
    if (index == NSNotFound) {
        [stack addObject:[self browserForDirectory:directory]];
    }
    else {
        NSURL *step = sources[index];
        [stack addObject:[self browserForDirectory:step]];
        NSArray<NSString *> *components = standardized.pathComponents;
        NSUInteger depth = step.URLByStandardizingPath.pathComponents.count;
        for (NSUInteger i = depth; i < components.count; i++) {
            step = [step URLByAppendingPathComponent:components[i] isDirectory:YES];
            [stack addObject:[self browserForDirectory:step]];
        }
    }
    [self.navigationController setViewControllers:stack animated:NO];
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
            return VibeBrowserSourceCount;
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
        BOOL sheet = [PlaylistFile isCueExtension:url.pathExtension.lowercaseString];
        content.image = [UIImage systemImageNamed:sheet ? @"music.note.list" : @"music.note"];
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
    if (indexPath.section == VibeBrowserRootSectionLocations) {
        NSUInteger count = SearchFolderStore.shared.folderURLs.count;
        NSUInteger row = (NSUInteger)indexPath.row;
        if (row < count) {
            content.text = [SearchFolderStore.shared displayNameForFolderAtIndex:row];
            content.image = [UIImage systemImageNamed:@"folder"];
        }
        else {
            content.text = row == count ? STR_SETTINGS_SEARCH_FOLDERS_ADD : STR_BROWSER_OTHER_FILES;
            content.image = [UIImage systemImageNamed:row == count ? @"folder.badge.plus" : @"doc.badge.ellipsis"];
            action = YES;
        }
    }
    else switch ((VibeBrowserSource)indexPath.row) {
        case VibeBrowserSourceDropbox:
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
        case VibeBrowserSourceDevice:
            content.text = [NSString stringWithFormat:STR_BROWSER_ON_DEVICE, UIDevice.currentDevice.localizedModel];
            content.image = [UIImage systemImageNamed:
                    UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"];
            break;
        case VibeBrowserSourceRecents:
            content.text = STR_BROWSER_RECENTS;
            content.image = [UIImage systemImageNamed:@"clock"];
            break;
        case VibeBrowserSourceCount:
            break;
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
    if (indexPath.section == VibeBrowserRootSectionLocations) {
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
    switch ((VibeBrowserSource)indexPath.row) {
        case VibeBrowserSourceDropbox: {
            DropboxMirror *mirror = DropboxMirror.shared;
            if (mirror.client.isLinked && mirror.accountURL) {
                [self pushDirectory:mirror.accountURL];
            }
            else {
                [mirror.client signInWithPresentationAnchor:self.view.window completion:^(NSError *error) {
                    if (error) {
                        LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
                        VibePresentAlert(self, VibeNotLocalized(@"Dropbox"), STR_SETTINGS_DROPBOX_CONNECT_FAILED);
                    }
                }];
            }
            return;
        }
        case VibeBrowserSourceDevice:
            [self pushDirectory:SearchFolderStore.containerDocumentsURL];
            return;
        case VibeBrowserSourceRecents:
            [self.navigationController pushViewController:[[RecentsViewController alloc] initWithPlayback:_playback
                                                                                                appending:_appending]
                                                 animated:YES];
            return;
        case VibeBrowserSourceCount:
            return;
    }
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
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
                [weakSelf openURLs:@[url] appending:NO];
            })];
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf openURLs:@[url] appending:YES];
        })];
        if (folder && !appendingSheet && ![FavoritesStore.shared containsFolderURL:url]) {
            NSString *title = [NSString stringWithFormat:STR_MENU_CONTEXT_ADD_FAVORITE, VibeAppName()];
            [items addObject:VibeMenuAction(title, @"star", ^{
                [weakSelf favoriteFolder:url];
            })];
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
        VibePresentAlert(self, STR_BROWSER_LOCATIONS, STR_SETTINGS_SEARCH_FOLDERS_COVERED);
    }
}

@end

@implementation RecentsViewController {
    PlaybackController *_playback;
    BOOL _appending;
    // Snapshotted per appearance, so an open landing under the finger does
    // not move the rows.
    NSArray<NSDictionary *> *_items;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _appending = appending;
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = STR_BROWSER_RECENTS;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _items = _playback.recentItems;
    [self.tableView reloadData];
    if (_items.count > 0) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    UIContentUnavailableConfiguration *empty = [UIContentUnavailableConfiguration emptyConfiguration];
    empty.image = [UIImage systemImageNamed:@"clock"];
    empty.text = STR_BROWSER_RECENTS_EMPTY;
    self.contentUnavailableConfiguration = empty;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kItemCellIdentifier]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kItemCellIdentifier];
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    NSString *path = item[@"path"];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = path.lastPathComponent;
    content.secondaryText = path.stringByDeletingLastPathComponent.lastPathComponent;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    content.image = [UIImage systemImageNamed:[item[@"folder"] boolValue] ? @"folder" : @"music.note"];
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openItem:_items[(NSUInteger)indexPath.row] appending:_appending inFolder:NO];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    BOOL folder = [item[@"folder"] boolValue];
    BOOL appendingSheet = _appending;
    __weak RecentsViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (!appendingSheet) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
                [weakSelf openItem:item appending:NO inFolder:NO];
            })];
            if (!folder) {
                [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"folder", ^{
                    [weakSelf openItem:item appending:NO inFolder:YES];
                })];
            }
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf openItem:item appending:YES inFolder:NO];
        })];
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_OPEN_FOLDER, @"folder", ^{
            [weakSelf showFolderOfItem:item];
        })];
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

// The resolve is provider IPC, so an Add takes its token first: a replace
// the user makes while it runs supersedes it (FolderSession).
- (void)openItem:(NSDictionary *)item appending:(BOOL)appending inFolder:(BOOL)inFolder {
    PlaybackController *playback = _playback;
    uint64_t token = appending ? [playback addRequestToken] : 0;
    BOOL folder = [item[@"folder"] boolValue];
    NSString *name = [item[@"path"] lastPathComponent];
    __weak RecentsViewController *weakSelf = self;
    [playback resolveRecentItem:item completion:^(NSURL *url) {
        if (!url) {
            [weakSelf showUnavailableAlertForName:name];
        }
        else if (appending) {
            [playback addURLs:@[url] token:token];
        }
        else if (folder) {
            [playback openURLs:@[url] openInPlace:YES];
        }
        else {
            [playback openFileURL:url inFolder:inFolder];
        }
    }];
    if (_appending) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    }
}

// The browser at the bottom of this stack shows the folder: the item
// itself, or the one holding it.
- (void)showFolderOfItem:(NSDictionary *)item {
    NSString *name = [item[@"path"] lastPathComponent];
    BOOL folder = [item[@"folder"] boolValue];
    __weak RecentsViewController *weakSelf = self;
    [_playback resolveRecentItem:item completion:^(NSURL *url) {
        RecentsViewController *strongSelf = weakSelf;
        BrowserViewController *root = (BrowserViewController *)strongSelf.navigationController.viewControllers.firstObject;
        if (!url) {
            [strongSelf showUnavailableAlertForName:name];
        }
        else if ([root isKindOfClass:BrowserViewController.class]) {
            [root showDirectory:folder ? url : url.URLByDeletingLastPathComponent];
        }
    }];
}

- (void)showUnavailableAlertForName:(NSString *)name {
    // In the add sheet the open already dismissed it.
    UIViewController *presenter = self.view.window ? self : self.navigationController.presentingViewController;
    if (presenter) {
        VibePresentAlert(presenter, name, STR_ERROR_RECENT_UNAVAILABLE);
    }
}

@end
