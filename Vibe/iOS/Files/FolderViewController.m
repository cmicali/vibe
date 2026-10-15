//
//  FolderViewController.m
//  Vibe (iOS)
//

#import "FolderViewControllerInternal.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "BrowserRules.h"
#import "DropboxMirror.h"
#import "EqualizerIndicatorView.h"
#import "FavoritesStore.h"
#import "FileRow.h"
#import "FilePaths.h"
#import "FolderWalk.h"
#import "LocationStore.h"
#import "PlaceholderFiles.h"
#import "PlaybackController.h"
#import "PlaybackController+ReplacePrompt.h"
#import "PlaylistFile.h"
#import "SettingsRules.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

static NSString *const kItemCellIdentifier = @"item";

// Going back to a folder relists it only this long after its last listing;
// pull to refresh always does.
static const CFTimeInterval kRelistInterval = 60;
// A larger selection lifts its first rows only: the rest would be a blur.
static const NSUInteger kMaximumLiftedRows = 6;
// How long Open Folder keeps the file it came from highlighted.
static const NSTimeInterval kHighlightInterval = 1.2;

@implementation FolderViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback
                    directoryURL:(NSURL *)directoryURL
                       appending:(BOOL)appending
                   stackArtCache:(AudioTrackMetadataCache *(^)(void))stackArtCache
                    highlighting:(NSURL *)file
                      holdsScope:(BOOL)holdsScope {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _directoryURL = [directoryURL copy];
        _appending = appending;
        _stackArtCache = [stackArtCache copy];
        _highlightURL = [file copy];
        _holdsScope = holdsScope;
        _allFolders = @[];
        _allFiles = @[];
        _folders = @[];
        _files = @[];
        _placeholders = [NSSet set];
        _fileSizes = @{};
        // TRAP: nothing here may touch the disk. A screen is made on main as
        // a folder opens, and for a provider's folder a stat or a name lookup
        // is IPC that can block.
        _dropboxPath = [DropboxMirror.shared dropboxPathForURL:directoryURL];
        _standardizedPath = VibeComparablePath(directoryURL.path);
        _title = [LocationStore displayNameForFolderURL:directoryURL];
        _playingPath = VibeComparablePath(playback.currentTrack.url.path);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(artThumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(dropboxDownloadsDidChange:)
                                               name:VibeDropboxDownloadsDidChangeNotification
                                             object:nil];
    if (_appending) {
        _closeItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                   target:self
                                                                   action:@selector(dismissSheet)];
    }
    self.navigationItem.title = _title;
    self.navigationItem.prompt = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : nil;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    // A tap is this folder alone, never its subfolders: the root of a
    // library would be one playlist. The long press takes them, capped.
    // The tap's action is set by refreshBarItems, which knows whether
    // there is anything directly inside to play.
    __weak FolderViewController *weakPlaySelf = self;
    _playItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:
                                                                _appending ? @"text.badge.plus" : @"play.fill"]
                                                  menu:[UIMenu menuWithChildren:@[VibeMenuAction(
            _appending ? STR_BROWSER_ADD_SUBFOLDERS : STR_BROWSER_PLAY_SUBFOLDERS, @"square.stack.3d.up", ^{
        [weakPlaySelf openDirectoryWithSubfolders];
    })]]];
    _playItem.accessibilityLabel = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : STR_MENU_CONTEXT_PLAY;
    _addSelectedItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"text.badge.plus"]
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(addSelected)];
    _addSelectedItem.accessibilityLabel = STR_MENU_CONTEXT_ADD_TO_PLAYLIST;
    _sortItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                  menu:[self sortMenu]];
    _sortItem.accessibilityLabel = STR_BROWSER_SORT;
    // "Select", not the system's "Edit": nothing here is edited. A glyph,
    // since the word beside two others truncates the folder's name.
    _selectItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(toggleSelecting)];
    _selectItem.accessibilityLabel = STR_BROWSER_SELECT;
    _doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                              target:self
                                                              action:@selector(toggleSelecting)];
    _selectAllItem = [[UIBarButtonItem alloc] initWithTitle:STR_MENU_EDIT_SELECT_ALL
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(selectAllRows)];
    // The filter field narrows this listing by name, installed once the
    // listing is long enough to need one (showFilterIfNeeded).
    _filter = [[UISearchController alloc] initWithSearchResultsController:nil];
    _filter.searchResultsUpdater = self;
    _filter.obscuresBackgroundDuringPresentation = NO;
    _filter.searchBar.placeholder = STR_BROWSER_FILTER;
    // TRAP: always shown, never hidden on scroll. A search bar that
    // collapses re-lays the bar out on the appearance callbacks the card's
    // expand and dismiss forward by hand, and the folder jumped under the
    // card. Stacked: iOS 26's integrated placement would put it in the
    // bottom toolbar, where the tab bar and the strip are.
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    [self refreshBarItems];
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshDirectory) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [_playback addObserver:self];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sourcesDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_holdsScope) {
        [_directoryURL stopAccessingSecurityScopedResource];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    // The track can change while this screen sits unloaded under another, so
    // the playing row is read again before the equalizer is placed.
    _playingPath = VibeComparablePath(_playback.currentTrack.url.path);
    [self syncEqualizer];
    [self reloadFromDisk];
    if (_dropboxPath && CFAbsoluteTimeGetCurrent() - _listedAt > kRelistInterval) {
        [self refreshFromDropbox];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self syncEqualizer];
}

// At the start of a transition; a cancelled one comes back through
// viewWillAppear:.
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _viewPresentationVisible = NO;
    [self syncEqualizer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _viewPresentationVisible = NO;
    [self syncEqualizer];
    // The stack's cache serves the screen on top: one gone from it stops
    // its own scan, and never the scan of the screen that replaced it.
    if (_artCache.delegate == self) {
        [_artCache cancelScan];
    }
}

// A download landed, or the downloads were removed: the mark and the art
// follow the file, so a mirrored folder on screen reads its listing again.
- (void)dropboxDownloadsDidChange:(NSNotification *)notification {
    if (_dropboxPath && self.viewIfLoaded.window) {
        [self reloadFromDisk];
    }
}

// The account went or came. A pushed Dropbox folder of a signed-out account
// has nothing left to show. The stack goes back to the root.
- (void)sourcesDidChange:(NSNotification *)notification {
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
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    __weak FolderViewController *weakSelf = self;
    // Off main: a granted location can be a provider's folder, whose listing
    // is IPC that can take seconds.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *folders = @[];
        NSArray<NSURL *> *playlists = @[];
        NSArray<NSURL *> *files = @[];
        [FolderWalk listDirectory:directory sortedBy:sort folders:&folders playlists:&playlists audio:&files];
        NSMutableSet<NSURL *> *placeholders = [NSMutableSet set];
        NSMutableDictionary<NSURL *, NSString *> *sizes = [NSMutableDictionary dictionary];
        // The songs, which may show cached art, and those whose bytes are
        // here, which art may be read from.
        NSMutableArray<NSURL *> *songs = [NSMutableArray array];
        NSMutableArray<NSURL *> *local = [NSMutableArray array];
        for (NSURL *url in files) {
            BOOL song = ![PlaylistFile isCueExtension:url.pathExtension.lowercaseString];
            if (song) {
                [songs addObject:url];
            }
            if ([PlaceholderFiles isRemotePlaceholderFile:url]) {
                [placeholders addObject:url];
            }
            else if (song && ![PlaceholderFiles isDatalessFile:url]) {
                [local addObject:url];
            }
            // A placeholder carries the remote size, so this is what a tap
            // would download. Formatted here, not per cell.
            NSNumber *size = nil;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
            if (size != nil && ![PlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
                sizes[url] = [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                                            countStyle:NSByteCountFormatterCountStyleFile];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            FolderViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_listingGeneration) {
                return;
            }
            strongSelf->_allFolders = folders;
            strongSelf->_allFiles = [playlists arrayByAddingObjectsFromArray:files];
            strongSelf->_hasSongs = files.count > 0;
            strongSelf->_placeholders = placeholders;
            strongSelf->_fileSizes = sizes;
            strongSelf->_songFiles = [NSSet setWithArray:songs];
            strongSelf->_localFiles = [NSSet setWithArray:local];
            // A new listing may hold a file cached since: ask again.
            strongSelf->_cacheOnlyAsked = [NSMutableSet set];
            [strongSelf showFilterIfNeeded];
            if (!strongSelf->_refreshing) {
                [strongSelf.refreshControl endRefreshing];
            }
            // A selection in progress is rows by index: it keeps its list.
            if (![strongSelf isSelecting]) {
                [strongSelf applyFilter];
            }
            [strongSelf showHighlightedFile];
            [strongSelf loadArtForVisibleRows];
        });
    });
}

// Pull to refresh: Dropbox is asked again; any other folder is relisted.
- (void)refreshDirectory {
    if (_dropboxPath) {
        [self refreshFromDropbox];
    }
    else {
        [self reloadFromDisk];
    }
}

- (void)refreshFromDropbox {
    if (_refreshing) {
        return;
    }
    _refreshing = YES;
    [self refreshEmptyState];
    __weak FolderViewController *weakSelf = self;
    [DropboxMirror.shared refreshDropboxFolder:_dropboxPath completion:^(NSURL *folderURL, NSError *error) {
        FolderViewController *strongSelf = weakSelf;
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

#pragma mark - The filter field

- (void)showFilterIfNeeded {
    if (VibeBrowserFolderWantsFilter(_allFolders.count + _allFiles.count,
                                     self.navigationItem.searchController != nil)) {
        self.navigationItem.searchController = _filter;
    }
}

- (NSString *)filterText {
    return _filter.searchBar.text ?: @"";
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (![self isSelecting]) {
        [self applyFilter];
        [self loadArtForVisibleRows];
    }
}

// The drawn rows from the listing: all of it, or the names holding the
// filter's text.
- (void)applyFilter {
    NSString *filter = [self filterText];
    if (filter.length == 0) {
        _folders = _allFolders;
        _files = _allFiles;
    }
    else {
        NSPredicate *matches = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            return [url.lastPathComponent localizedStandardContainsString:filter];
        }];
        _folders = [_allFolders filteredArrayUsingPredicate:matches];
        _files = [_allFiles filteredArrayUsingPredicate:matches];
    }
    [self.tableView reloadData];
    [self refreshEmptyState];
    [self refreshBarItems];
}

- (BOOL)isEmpty {
    return _allFolders.count == 0 && _allFiles.count == 0;
}

- (void)refreshEmptyState {
    UIContentUnavailableConfiguration *empty = nil;
    switch (VibeBrowserFolderEmptyStateFor(_allFolders.count + _allFiles.count, _folders.count + _files.count,
                                           _refreshing, _refreshError != nil)) {
        case VibeBrowserFolderEmptyStateNone:
            break;
        case VibeBrowserFolderEmptyStateNoMatches:
            empty = [UIContentUnavailableConfiguration searchConfiguration];
            break;
        case VibeBrowserFolderEmptyStateLoading:
            empty = [UIContentUnavailableConfiguration loadingConfiguration];
            break;
        case VibeBrowserFolderEmptyStateUnavailable:
            empty = [UIContentUnavailableConfiguration emptyConfiguration];
            empty.image = [UIImage systemImageNamed:@"wifi.exclamationmark"];
            empty.text = STR_BROWSER_DROPBOX_UNAVAILABLE;
            break;
        case VibeBrowserFolderEmptyStateEmpty:
            empty = [UIContentUnavailableConfiguration emptyConfiguration];
            empty.image = [UIImage systemImageNamed:@"music.note"];
            empty.text = STR_ERROR_FOLDER_EMPTY;
            break;
    }
    self.contentUnavailableConfiguration = empty;
}

#pragma mark - Opening

- (void)addURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    [_playback addURLs:urls];
    if (_appending) {
        [self dismissSheet];
    }
}

// A replace — a file alone, a file with its folder, a folder, or a pick of
// several — unless this is the add sheet, where the same pick is added.
- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder {
    if (_appending) {
        [self addURLs:urls];
        return;
    }
    NSURL *row = urls.count == 1 ? urls.firstObject : nil;
    [self openURLs:urls inFolder:inFolder token:[_playback replaceRequestTokenOpening:row]];
}

// For the subfolder walk, whose Dropbox listings come between the tap and
// the open: its token is the tap's.
- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder token:(uint64_t)token {
    if (_appending) {
        [self addURLs:urls];
        return;
    }
    [_playback confirmReplacingPlaylistFrom:self openingURLs:urls inFolder:inFolder token:token];
}

- (void)openDirectory {
    [self openURLs:@[_directoryURL] inFolder:NO];
}

// This folder and the folders inside it, depth first in the listing's order,
// as one open: the first folder with songs is the base and the rest are
// additions, each listed flat as any folder is.
- (void)openDirectoryWithSubfolders {
    if (_walkingSubfolders) {
        return;
    }
    _walkingSubfolders = YES;
    uint64_t token = [_playback replaceRequestTokenOpening:nil];
    __weak FolderViewController *weakSelf = self;
    [self walkSubfolders:[NSMutableArray arrayWithObject:_directoryURL]
                   found:[NSMutableArray array]
                  tracks:0
                 visited:0
              completion:^(NSArray<NSURL *> *folders, BOOL capped) {
        FolderViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_walkingSubfolders = NO;
        if (folders.count == 0) {
            [strongSelf vibePresentAlertWithTitle:strongSelf->_title message:STR_ERROR_FOLDER_EMPTY];
            return;
        }
        void (^open)(void) = ^{
            [strongSelf openURLs:folders inFolder:NO token:token];
        };
        if (!capped) {
            open();
            return;
        }
        UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:strongSelf->_title
                                 message:[NSString stringWithFormat:STR_BROWSER_SUBFOLDERS_CAPPED,
                                                  (unsigned long)kVibeBrowserMaximumSubfolderTracks]
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) { open(); }]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

// One folder per turn. A Dropbox folder is listed from Dropbox first: the
// mirror holds only what something has listed, so one never browsed is empty
// on disk. Completion on main; capped means folders were left unvisited.
- (void)walkSubfolders:(NSMutableArray<NSURL *> *)pending
                 found:(NSMutableArray<NSURL *> *)found
                tracks:(NSUInteger)tracks
               visited:(NSUInteger)visited
            completion:(void (^)(NSArray<NSURL *> *folders, BOOL capped))completion {
    if (VibeBrowserSubfolderWalkStops(pending.count, tracks, visited)) {
        completion(found, pending.count > 0);
        return;
    }
    NSURL *directory = pending.firstObject;
    [pending removeObjectAtIndex:0];
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    __weak FolderViewController *weakSelf = self;
    dispatch_block_t list = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSURL *> *subfolders = @[];
            NSArray<NSURL *> *audio = @[];
            [FolderWalk listDirectory:directory sortedBy:sort folders:&subfolders playlists:NULL audio:&audio];
            NSUInteger songs = audio.count;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (songs > 0) {
                    [found addObject:directory];
                }
                // Ahead of its siblings: depth first.
                [pending insertObjects:subfolders
                             atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, subfolders.count)]];
                [weakSelf walkSubfolders:pending found:found tracks:tracks + songs visited:visited + 1
                              completion:completion];
            });
        });
    };
    // The open that follows reads a listed folder as it is, so each is
    // listed once.
    NSString *dropboxPath = [DropboxMirror.shared dropboxPathForURL:directory];
    if (dropboxPath) {
        [DropboxMirror.shared refreshDropboxFolder:dropboxPath completion:^(NSURL *folderURL, NSError *error) {
            list();
        }];
    }
    else {
        list();
    }
}

// The rows of an Add, lifted for the shell to carry into the Playlist tab.
// Not in the add sheet, which closes onto the playlist itself.
- (void)liftRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    if (!_addedRowsHandler) {
        return;
    }
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    for (NSIndexPath *indexPath in indexPaths) {
        if (rows.count == kMaximumLiftedRows) {
            break;
        }
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        UIView *row = [cell snapshotViewAfterScreenUpdates:NO];
        if (row) {
            row.frame = [cell convertRect:cell.bounds toView:nil];
            [rows addObject:row];
        }
    }
    _addedRowsHandler(rows);
}

- (void)addSelected {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    // In row order, which is the order a reader of the list expects.
    NSArray<NSIndexPath *> *selected = [self.tableView.indexPathsForSelectedRows
            sortedArrayUsingSelector:@selector(compare:)];
    [self liftRowsAtIndexPaths:selected];
    for (NSIndexPath *indexPath in selected) {
        NSURL *url = [self itemAtIndexPath:indexPath];
        if (url) {
            [urls addObject:url];
        }
    }
    [self setEditing:NO animated:YES];
    [self addURLs:urls];
}

// By its presenter, so Open URL's sheet over it closes with it.
- (void)dismissSheet {
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)pushDirectory:(NSURL *)url {
    FolderViewController *folder = [[FolderViewController alloc] initWithPlayback:_playback
                                                                     directoryURL:url
                                                                        appending:_appending
                                                                    stackArtCache:_stackArtCache
                                                                     highlighting:nil
                                                                       holdsScope:NO];
    folder.addedRowsHandler = _addedRowsHandler;
    folder.equalizerSurfaceVisible = _equalizerSurfaceVisible;
    [self.navigationController pushViewController:folder animated:YES];
}

// Open Folder arrives on the file it came from: scrolled to and selected for
// a moment, once a listing holds it.
- (void)showHighlightedFile {
    if (!_highlightURL) {
        return;
    }
    NSString *name = _highlightURL.lastPathComponent;
    NSUInteger row = [_files indexOfObjectPassingTest:^BOOL(NSURL *url, NSUInteger i, BOOL *stop) {
        return [url.lastPathComponent isEqualToString:name];
    }];
    if (row == NSNotFound) {
        return;   // a Dropbox folder not listed yet: the relist's landing tries again
    }
    _highlightURL = nil;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)row inSection:VibeBrowserSectionFiles];
    [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionMiddle];
    __weak FolderViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHighlightInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FolderViewController *strongSelf = weakSelf;
        if (strongSelf && ![strongSelf isSelecting]) {
            [strongSelf.tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    });
}

- (void)favoriteFolder:(NSURL *)url {
    // A failed mint adds no row: one without a bookmark cannot be opened.
    [_playback bookmarkFolderURL:url completion:^(NSData *bookmark) {
        if (bookmark) {
            [FavoritesStore.shared addFolderURL:url bookmark:bookmark];
        }
    }];
}

#pragma mark - PlaybackObserver

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    _playingPath = VibeComparablePath(playback.currentTrack.url.path);
    if (self.viewIfLoaded.window && ![self isSelecting]) {
        [self.tableView reloadData];
    }
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self syncEqualizer];
}

- (void)playbackDidChangeOpening:(PlaybackController *)playback {
    if (self.viewIfLoaded.window && ![self isSelecting]) {
        [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)VibeBrowserSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(section == VibeBrowserSectionFolders ? _folders.count : _files.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // A relist that failed over rows already here: they may be out of date.
    if (section == VibeBrowserSectionFiles && _refreshError && !self.isEmpty) {
        return STR_BROWSER_DROPBOX_UNAVAILABLE;
    }
    return nil;
}

- (UITableViewCell *)cellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    // An item row keeps its equalizer through reuse and reconfiguration; it
    // decides its own accessory (cellForRowAtIndexPath:).
    if (![cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]) {
        cell.accessoryView = nil;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self cellWithIdentifier:kItemCellIdentifier];
    NSURL *url = [self itemAtIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = url.lastPathComponent;
    [content vibeApplyFileNameStyle];
    BOOL isFolder = indexPath.section == VibeBrowserSectionFolders;
    [content vibeApplyFileIconForName:url.lastPathComponent folder:isFolder art:[_artTracks[url] cachedThumbnail]];
    NSString *path = [_standardizedPath stringByAppendingPathComponent:url.lastPathComponent];
    EqualizerIndicatorView *equalizer = [cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]
            ? (EqualizerIndicatorView *)cell.accessoryView : nil;
    UIView *accessory = nil;
    if (isFolder) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else {
        // From the stat alone: what the file takes, or would download.
        content.secondaryText = _fileSizes[url];
        if (_playingPath && [path isEqualToString:_playingPath]) {
            accessory = equalizer ?: [self makeEqualizer];
        }
        else if ([_placeholders containsObject:url]) {
            accessory = VibeNotDownloadedMark();
        }
    }
    if (equalizer && accessory != equalizer) {
        equalizer.presentationVisible = NO;
        equalizer.audioOutputActive = NO;
    }
    cell.accessoryView = accessory;
    [cell vibeApplyRowContent:content opening:[path isEqualToString:_playback.openingPath]];
    return cell;
}

- (NSURL *)itemAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSURL *> *items = indexPath.section == VibeBrowserSectionFolders ? _folders : _files;
    return (NSUInteger)indexPath.row < items.count ? items[(NSUInteger)indexPath.row] : nil;
}

#pragma mark - The playing row's equalizer

- (EqualizerIndicatorView *)makeEqualizer {
    EqualizerIndicatorView *equalizer = [[EqualizerIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 16, 14)];
    equalizer.levelSource = _playback;
    return equalizer;
}

// A screen not loaded yet syncs when it appears.
- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    if (self.isViewLoaded) {
        [self syncEqualizer];
    }
}

// Actual output plus material visibility, the root guarantee's two facts.
- (void)syncEqualizer {
    BOOL surface = _viewPresentationVisible && _equalizerSurfaceVisible;
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]) {
            EqualizerIndicatorView *equalizer = (EqualizerIndicatorView *)cell.accessoryView;
            equalizer.audioOutputActive = _playback.audioOutputActive;
            equalizer.presentationVisible = surface && [cell vibeIsInViewportOfTableView:self.tableView];
        }
    }
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    [self syncEqualizer];
}

- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]) {
        EqualizerIndicatorView *equalizer = (EqualizerIndicatorView *)cell.accessoryView;
        equalizer.presentationVisible = NO;
        equalizer.audioOutputActive = NO;
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self syncEqualizer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self syncEqualizer];
}

@end
