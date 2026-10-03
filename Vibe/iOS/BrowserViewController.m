//
//  BrowserViewController.m
//  Vibe (iOS)
//

#import "BrowserViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AppSettings.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "DocumentTypes.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "PlaybackController.h"
#import "PlaylistFile.h"
#import "SearchFolderStore.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeBrowserRootSection) {
    VibeBrowserRootSectionSources = 0,
    // Its own group: a place to go back to, not a place files live.
    VibeBrowserRootSectionRecents,
    // Last: its footer needs the room a last section has.
    VibeBrowserRootSectionLocations,
    VibeBrowserRootSectionCount,
};

// What a row of the root is. Sources: the device, and Dropbox once linked.
// Recents, alone. Locations: the granted folders, then the rows that add one,
// with Connect to Dropbox among them until an account is linked.
typedef NS_ENUM(NSInteger, VibeBrowserRootRow) {
    VibeBrowserRootRowDevice = 0,
    VibeBrowserRootRowDropbox,
    VibeBrowserRootRowRecents,
    VibeBrowserRootRowLocation,
    VibeBrowserRootRowConnectDropbox,
    VibeBrowserRootRowAddFolder,
    VibeBrowserRootRowBrowseFiles,
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
// A larger selection lifts its first rows only: the rest would be a blur.
static const NSUInteger kMaximumLiftedRows = 6;
// Play with Subfolders stops here: a library's root would otherwise become
// one playlist. Whole folders are taken, so the count can run a little over.
static const NSUInteger kMaximumSubfolderTracks = 2000;
static const NSUInteger kMaximumSubfolders = 500;
// A listing at least this long gets the filter field; a short one is read
// at a glance and the field would only cost its height.
static const NSUInteger kFilterThreshold = 12;
// How long Open Folder keeps the file it came from highlighted.
static const NSTimeInterval kHighlightInterval = 1.2;

@interface BrowserViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating, PlaybackObserver,
        AudioTrackMetadataCacheDelegate>
@end

// Every file and folder played or added, newest first (FolderSession). A file
// plays alone, as a search hit does; a folder opens in the browser. Its own
// screen rather than a browser mode: it lists no directory, and every one of
// the browser's directory branches would need a third arm.
@interface RecentsViewController : UITableViewController
- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending;
@end

void VibePresentAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void)) {
    return [UIAction actionWithTitle:title
                               image:[UIImage systemImageNamed:symbol]
                          identifier:nil
                             handler:^(UIAction *action) {
        handler();
    }];
}

// A file or folder name: two lines, cut in the middle, so the ends that tell
// two long names apart both show.
void VibeApplyFileNameStyle(UIListContentConfiguration *content) {
    content.textProperties.numberOfLines = 2;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
}

// The mark on a row whose file is not downloaded: a tap waits on the network.
UIView *VibeNotDownloadedMark(void) {
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    mark.tintColor = UIColor.secondaryLabelColor;
    return mark;
}

const CGFloat VibeFileTileSide = 40;
const CGFloat VibeFileTileCornerRadius = 8;

// Drawn once per symbol, in both appearances: an image asset holding the
// light and the dark tile follows the trait collection by itself, which a
// single rendered image would not.
UIImage *VibeFileTileImage(NSString *symbol) {
    static NSMutableDictionary<NSString *, UIImage *> *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSMutableDictionary dictionary];
    });
    UIImage *tile = tiles[symbol];
    if (tile) {
        return tile;
    }
    CGRect bounds = CGRectMake(0, 0, VibeFileTileSide, VibeFileTileSide);
    UIImage *(^draw)(UIUserInterfaceStyle) = ^UIImage *(UIUserInterfaceStyle style) {
        UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:style];
        UIImageSymbolConfiguration *configuration =
                [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
        UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:configuration]
                imageWithTintColor:[UIColor.secondaryLabelColor resolvedColorWithTraitCollection:traits]
                     renderingMode:UIImageRenderingModeAlwaysOriginal];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size];
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor.secondarySystemFillColor resolvedColorWithTraitCollection:traits] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:VibeFileTileCornerRadius] fill];
            [glyph drawAtPoint:CGPointMake(CGRectGetMidX(bounds) - glyph.size.width / 2,
                                           CGRectGetMidY(bounds) - glyph.size.height / 2)];
        }];
    };
    tile = draw(UIUserInterfaceStyleLight);
    [tile.imageAsset registerImage:draw(UIUserInterfaceStyleDark)
               withTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
    tiles[symbol] = tile;
    return tile;
}

@implementation BrowserViewController {
    PlaybackController *_playback;
    NSURL *_directoryURL;
    BOOL _appending;

    // A directory's whole listing, sorted as the Files app sorts names; which
    // of the files are Dropbox placeholders and each file's size — found with
    // the listing, off main.
    NSArray<NSURL *> *_allFolders;
    NSArray<NSURL *> *_allFiles;
    NSSet<NSURL *> *_placeholders;
    NSDictionary<NSURL *, NSString *> *_fileSizes;
    // The directory's standardized path, so a row's is one append away.
    NSString *_standardizedPath;
    NSString *_title;
    // The playing file's standardized path, for the row that carries the mark.
    NSString *_playingPath;
    // The rows drawn: the listing narrowed by the filter field.
    NSArray<NSURL *> *_folders;
    NSArray<NSURL *> *_files;
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
    // Open Folder's file, shown and briefly selected once the listing lands.
    NSURL *_highlightURL;
    // Open Folder on a folder no persistent root covers (a one-off pick in
    // Recents): this screen holds its scope, and the subfolders pushed above
    // it read under it. The session's hold may be gone with the playlist.
    BOOL _holdsScope;

    // Album art for the listing's files already on the device, through the
    // app's own metadata sweep: a track per local file, by URL, and whether
    // a sweep over them is out.
    AudioTrackMetadataCache *_artCache;
    NSDictionary<NSURL *, AudioTrack *> *_artTracks;
    BOOL _artScanActive;

    // Which picker is up: a location grant, or a one-off pick.
    BOOL _pickingLocation;
    // A row swipe sets isEditing too; only the Select button's is multi-select.
    BOOL _swipingRow;
    // A subfolder walk is out; a second ask waits for it.
    BOOL _walkingSubfolders;
    UIBarButtonItem *_playItem;
    UIBarButtonItem *_addSelectedItem;
    UIBarButtonItem *_sortItem;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_selectAllItem;
    UIBarButtonItem *_closeItem;
    UISearchController *_filter;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback
                    directoryURL:(NSURL *)directoryURL
                       appending:(BOOL)appending {
    self = [super initWithStyle:directoryURL ? UITableViewStylePlain : UITableViewStyleInsetGrouped];
    if (self) {
        _playback = playback;
        _directoryURL = [directoryURL copy];
        _appending = appending;
        _allFolders = @[];
        _allFiles = @[];
        _folders = @[];
        _files = @[];
        _placeholders = [NSSet set];
        _fileSizes = @{};
        _dropboxPath = directoryURL ? [DropboxMirror.shared dropboxPathForURL:directoryURL] : nil;
        _standardizedPath = directoryURL.URLByStandardizingPath.path;
        _title = directoryURL ? [SearchFolderStore displayNameForFolderURL:directoryURL] : nil;
        _playingPath = playback.currentTrack.url.URLByStandardizingPath.path;
    }
    return self;
}

- (BOOL)isRoot {
    return _directoryURL == nil;
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
    if (self.isRoot) {
        // The add sheet says what a tap in it does: it is the Files tab's
        // twin, and there a tap plays.
        self.navigationItem.title = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : STR_TAB_FILES;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
        self.navigationController.navigationBar.prefersLargeTitles = YES;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(sourcesDidChange:)
                                                   name:VibeSearchFoldersDidChangeNotification
                                                 object:SearchFolderStore.shared];
        if (_appending && self.navigationController.viewControllers.firstObject == self) {
            self.navigationItem.leftBarButtonItem = _closeItem;
        }
    }
    else {
        self.navigationItem.title = _title;
        self.navigationItem.prompt = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : nil;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        self.tableView.allowsMultipleSelectionDuringEditing = YES;
        // A tap is this folder alone, never its subfolders: the root of a
        // library would be one playlist. The long press takes them, capped.
        // The tap's action is set by refreshBarItems, which knows whether
        // there is anything directly inside to play.
        __weak BrowserViewController *weakPlaySelf = self;
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
    }
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sourcesDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_artCache cancelScan];
    if (_holdsScope) {
        [_directoryURL stopAccessingSecurityScopedResource];
    }
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

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // One sweep at a time down a stack of folders; the return restarts it.
    [_artCache cancelScan];
    _artScanActive = NO;
}

// A download landed, or the downloads were removed: the mark and the art
// follow the file, so a mirrored folder on screen reads its listing again.
- (void)dropboxDownloadsDidChange:(NSNotification *)notification {
    if (_dropboxPath && self.viewIfLoaded.window) {
        [self reloadFromDisk];
    }
}

#pragma mark - Album art

// TRAP: only files whose bytes are on the device are asked. The sweep reads
// a cache miss's tags from the file, which for a Dropbox placeholder is
// ranged requests and for a provider's dataless file a download: browsing a
// folder costs nothing a row does not say. A file seen before answers from
// the metadata cache without being read at all.
- (void)loadArtForFiles:(NSArray<NSURL *> *)local {
    NSMutableDictionary<NSURL *, AudioTrack *> *tracks = [NSMutableDictionary dictionaryWithCapacity:local.count];
    NSMutableArray<AudioTrack *> *pending = [NSMutableArray array];
    BOOL fresh = NO;
    for (NSURL *url in local) {
        AudioTrack *track = _artTracks[url];
        if (!track) {
            track = [AudioTrack withURL:url];
            fresh = YES;
        }
        tracks[url] = track;
        if (!track.metadata) {
            [pending addObject:track];
        }
    }
    _artTracks = tracks;
    // A relist that found nothing new leaves a running sweep alone: asking
    // again would restart it.
    if (pending.count == 0 || (_artScanActive && !fresh)) {
        return;
    }
    if (!_artCache) {
        _artCache = [[AudioTrackMetadataCache alloc] init];
        _artCache.delegate = self;
    }
    _artScanActive = YES;
    [_artCache loadMetadata:pending];
    [self rankArtByVisibleRows];
}

- (AudioTrack *)artTrackAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isRoot || indexPath.section != VibeBrowserSectionFiles
            || (NSUInteger)indexPath.row >= _files.count) {
        return nil;
    }
    return _artTracks[_files[(NSUInteger)indexPath.row]];
}

// The sweep reads the rows on screen first.
- (void)rankArtByVisibleRows {
    if (!_artScanActive) {
        return;
    }
    NSMutableArray<AudioTrack *> *visible = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        AudioTrack *track = [self artTrackAtIndexPath:indexPath];
        if (track) {
            [visible addObject:track];
        }
    }
    [_artCache setNeighborhoodTracks:visible];
}

- (void)redrawVisibleRowsWhoseTrack:(BOOL (^)(AudioTrack *track))matches {
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        AudioTrack *track = [self artTrackAtIndexPath:indexPath];
        if (track && matches(track)) {
            [rows addObject:indexPath];
        }
    }
    if (rows.count > 0) {
        [self.tableView reconfigureRowsAtIndexPaths:rows];
    }
}

// The tags landed; the row's next draw asks for the thumbnail, whose pixels
// arrive by the notification below.
- (void)didLoadMetadata:(AudioTrack *)track {
    [self redrawVisibleRowsWhoseTrack:^BOOL(AudioTrack *shown) {
        return shown == track;
    }];
}

- (void)artThumbnailDidLoad:(NSNotification *)notification {
    [self redrawVisibleRowsWhoseTrack:^BOOL(AudioTrack *shown) {
        return shown.metadata == notification.object;
    }];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self rankArtByVisibleRows];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self rankArtByVisibleRows];
    }
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
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    __weak BrowserViewController *weakSelf = self;
    // Off main: a granted location can be a provider's folder, whose listing
    // is IPC that can take seconds.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *folders = @[];
        NSArray<NSURL *> *files = @[];
        [NSURLUtil listDirectory:directory sortedBy:sort folders:&folders audio:&files];
        NSMutableSet<NSURL *> *placeholders = [NSMutableSet set];
        NSMutableDictionary<NSURL *, NSString *> *sizes = [NSMutableDictionary dictionary];
        // The audio whose bytes are here: what art may be read from.
        NSMutableArray<NSURL *> *local = [NSMutableArray array];
        for (NSURL *url in files) {
            if ([NSURLUtil isRemotePlaceholderFile:url]) {
                [placeholders addObject:url];
            }
            else if (![PlaylistFile isCueExtension:url.pathExtension.lowercaseString]
                    && ![NSURLUtil isDatalessFile:url]) {
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
            BrowserViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_listingGeneration) {
                return;
            }
            strongSelf->_allFolders = folders;
            strongSelf->_allFiles = files;
            strongSelf->_placeholders = placeholders;
            strongSelf->_fileSizes = sizes;
            [strongSelf loadArtForFiles:local];
            [strongSelf showFilterIfNeeded];
            if (!strongSelf->_refreshing) {
                [strongSelf.refreshControl endRefreshing];
            }
            // A selection in progress is rows by index: it keeps its list.
            if (![strongSelf isSelecting]) {
                [strongSelf applyFilter];
            }
            [strongSelf showHighlightedFile];
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

#pragma mark - The filter field

// Installed, never removed: a folder that shrinks below the threshold keeps
// a field the user may be typing in.
- (void)showFilterIfNeeded {
    if (!self.navigationItem.searchController && _allFolders.count + _allFiles.count >= kFilterThreshold) {
        self.navigationItem.searchController = _filter;
    }
}

- (NSString *)filterText {
    return _filter.searchBar.text ?: @"";
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (![self isSelecting]) {
        [self applyFilter];
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
    if (self.isRoot) {
        return;
    }
    if (!self.isEmpty) {
        // A filter that matches nothing is a search with no results.
        self.contentUnavailableConfiguration = _folders.count == 0 && _files.count == 0
                ? [UIContentUnavailableConfiguration searchConfiguration] : nil;
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

#pragma mark - The bar

// Multi-select, as opposed to the editing state a row swipe also sets.
- (BOOL)isSelecting {
    return self.tableView.isEditing && !_swipingRow;
}

- (void)refreshBarItems {
    if (self.isRoot) {
        return;
    }
    if ([self isSelecting]) {
        NSUInteger count = self.tableView.indexPathsForSelectedRows.count;
        _addSelectedItem.enabled = count > 0;
        self.navigationItem.title = [NSString stringWithFormat:STR_BROWSER_SELECTED_COUNT, (unsigned long)count];
        self.navigationItem.rightBarButtonItems = @[_doneItem, _addSelectedItem];
        self.navigationItem.leftBarButtonItem = _selectAllItem;
        self.navigationItem.hidesBackButton = YES;
        return;
    }
    self.navigationItem.title = _title;
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.hidesBackButton = NO;
    // Absent, not disabled, with nothing to act on: the Playlist tab's rule.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    // The add sheet is modal and needs its way out at every level.
    if (_closeItem) {
        [items addObject:_closeItem];
    }
    if (!self.isEmpty) {
        [items addObject:_selectItem];
        // With no song directly inside, the tap has nothing to play and the
        // button is its menu alone.
        _playItem.target = _allFiles.count > 0 ? self : nil;
        _playItem.action = _allFiles.count > 0 ? @selector(openDirectory) : NULL;
        [items addObject:_playItem];
        // Not in the add sheet: with Close the bar has no room, and the
        // order is a setting the Files tab changes.
        if (!_appending) {
            [items addObject:_sortItem];
        }
    }
    self.navigationItem.rightBarButtonItems = items;
}

// Built when opened, so its check follows a change made on another screen.
// The title says what the choice reaches: it is the one folder-open setting,
// not this folder's view.
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
    return [UIMenu menuWithTitle:STR_BROWSER_SORT_TITLE children:@[choices]];
}

- (void)toggleSelecting {
    [self setEditing:!self.tableView.isEditing animated:YES];
}

- (void)selectAllRows {
    for (NSInteger section = 0; section < VibeBrowserSectionCount; section++) {
        NSInteger rows = [self.tableView numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                                        animated:NO
                                  scrollPosition:UITableViewScrollPositionNone];
        }
    }
    [self refreshBarItems];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self refreshBarItems];
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    _swipingRow = YES;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    _swipingRow = NO;
    [self refreshBarItems];
}

- (NSURL *)itemAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSURL *> *items = indexPath.section == VibeBrowserSectionFolders ? _folders : _files;
    return (NSUInteger)indexPath.row < items.count ? items[(NSUInteger)indexPath.row] : nil;
}

#pragma mark - Opening

+ (void)confirmReplacingPlaylistOf:(PlaybackController *)playback
                              from:(UIViewController *)presenter
                       openingURLs:(NSArray<NSURL *> *)urls
                          inFolder:(BOOL)inFolder {
    if (urls.count == 0) {
        return;
    }
    dispatch_block_t replace = ^{
        if (urls.count == 1) {
            [playback openFileURL:urls.firstObject inFolder:inFolder];
        }
        else {
            [playback openURLs:urls openInPlace:YES];
        }
    };
    if (!playback.playlistHasAdditions) {
        replace();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:STR_PLAYLIST_REPLACE_TITLE
                                                                   message:STR_PLAYLIST_REPLACE_MESSAGE
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_CONFIRM
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { replace(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_ADD
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { [playback addURLs:urls]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// Every open is one of PlaybackController's roads.
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
    [BrowserViewController confirmReplacingPlaylistOf:_playback from:self openingURLs:urls inFolder:inFolder];
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
    __weak BrowserViewController *weakSelf = self;
    [self walkSubfolders:[NSMutableArray arrayWithObject:_directoryURL]
                   found:[NSMutableArray array]
                  tracks:0
                 visited:0
              completion:^(NSArray<NSURL *> *folders, BOOL capped) {
        BrowserViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_walkingSubfolders = NO;
        if (folders.count == 0) {
            VibePresentAlert(strongSelf, strongSelf->_title, STR_ERROR_FOLDER_EMPTY);
            return;
        }
        void (^open)(void) = ^{
            [strongSelf openURLs:folders inFolder:NO];
        };
        if (!capped) {
            open();
            return;
        }
        UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:strongSelf->_title
                                 message:[NSString stringWithFormat:STR_BROWSER_SUBFOLDERS_CAPPED,
                                                  (unsigned long)kMaximumSubfolderTracks]
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
    if (pending.count == 0 || tracks >= kMaximumSubfolderTracks || visited >= kMaximumSubfolders) {
        completion(found, pending.count > 0);
        return;
    }
    NSURL *directory = pending.firstObject;
    [pending removeObjectAtIndex:0];
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    __weak BrowserViewController *weakSelf = self;
    dispatch_block_t list = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSURL *> *subfolders = @[];
            NSArray<NSURL *> *audio = @[];
            [NSURLUtil listDirectory:directory sortedBy:sort folders:&subfolders audio:&audio];
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

- (void)dismissSheet {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (BrowserViewController *)browserForDirectory:(NSURL *)url {
    BrowserViewController *browser = [[BrowserViewController alloc] initWithPlayback:_playback
                                                                        directoryURL:url
                                                                           appending:_appending];
    browser.addedRowsHandler = _addedRowsHandler;
    return browser;
}

- (void)pushDirectory:(NSURL *)url {
    [self.navigationController pushViewController:[self browserForDirectory:url] animated:YES];
}

- (void)showDirectory:(NSURL *)directory highlighting:(NSURL *)file {
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
        BrowserViewController *browser = [self browserForDirectory:directory];
        // A bookmark's URL carries the grant; a path-derived one answers NO.
        browser->_holdsScope = [directory startAccessingSecurityScopedResource];
        [stack addObject:browser];
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
    ((BrowserViewController *)stack.lastObject)->_highlightURL = [file copy];
    [self.navigationController setViewControllers:stack animated:NO];
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
    __weak BrowserViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHighlightInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BrowserViewController *strongSelf = weakSelf;
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

// The playing file's row carries the mark.
- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    _playingPath = playback.currentTrack.url.URLByStandardizingPath.path;
    if (self.viewIfLoaded.window && ![self isSelecting]) {
        [self.tableView reloadData];
    }
}

#pragma mark - Table

- (NSArray<NSNumber *> *)rootRowsInSection:(NSInteger)section {
    BOOL linked = DropboxMirror.shared.client.isLinked;
    if (section == VibeBrowserRootSectionSources) {
        return linked ? @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowDropbox)] : @[@(VibeBrowserRootRowDevice)];
    }
    if (section == VibeBrowserRootSectionRecents) {
        return @[@(VibeBrowserRootRowRecents)];
    }
    NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
    // First, so a location's row is its index in the store.
    NSUInteger locations = SearchFolderStore.shared.folderURLs.count;
    for (NSUInteger i = 0; i < locations; i++) {
        [rows addObject:@(VibeBrowserRootRowLocation)];
    }
    if (!linked) {
        [rows addObject:@(VibeBrowserRootRowConnectDropbox)];
    }
    [rows addObject:@(VibeBrowserRootRowAddFolder)];
    [rows addObject:@(VibeBrowserRootRowBrowseFiles)];
    return rows;
}

- (VibeBrowserRootRow)rootRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *rows = [self rootRowsInSection:indexPath.section];
    return (NSUInteger)indexPath.row < rows.count
            ? (VibeBrowserRootRow)rows[(NSUInteger)indexPath.row].integerValue : VibeBrowserRootRowBrowseFiles;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.isRoot ? (NSInteger)VibeBrowserRootSectionCount : (NSInteger)VibeBrowserSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.isRoot) {
        return (NSInteger)(section == VibeBrowserSectionFolders ? _folders.count : _files.count);
    }
    return (NSInteger)[self rootRowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.isRoot && section == VibeBrowserRootSectionLocations) {
        return STR_BROWSER_LOCATIONS;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.isRoot) {
        return section == VibeBrowserRootSectionLocations ? STR_BROWSER_LOCATIONS_FOOTER : nil;
    }
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
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = url.lastPathComponent;
    VibeApplyFileNameStyle(content);
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // Art and the tiles are one size, and every row reserves it, so the
    // names line up down a listing of folders, files and the playing row.
    content.imageProperties.reservedLayoutSize = CGSizeMake(VibeFileTileSide, VibeFileTileSide);
    content.imageProperties.maximumSize = CGSizeMake(VibeFileTileSide, VibeFileTileSide);
    if (indexPath.section == VibeBrowserSectionFolders) {
        content.image = [UIImage systemImageNamed:@"folder"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else {
        BOOL sheet = [PlaylistFile isCueExtension:url.pathExtension.lowercaseString];
        BOOL playing = _playingPath
                && [[_standardizedPath stringByAppendingPathComponent:url.lastPathComponent]
                        isEqualToString:_playingPath];
        if (playing) {
            content.image = [UIImage systemImageNamed:@"speaker.wave.2.fill"];
            content.imageProperties.tintColor = self.view.tintColor;
        }
        else {
            // Its art when the file is here and has some; else the tile.
            content.image = [_artTracks[url] cachedThumbnail]
                    ?: VibeFileTileImage(sheet ? @"music.note.list" : @"waveform");
            content.imageProperties.cornerRadius = VibeFileTileCornerRadius;
        }
        // From the stat alone: what the file takes, or would download.
        content.secondaryText = _fileSizes[url];
        if ([_placeholders containsObject:url]) {
            cell.accessoryView = VibeNotDownloadedMark();
        }
    }
    cell.contentConfiguration = content;
    return cell;
}

- (UITableViewCell *)sourceCellAtIndexPath:(NSIndexPath *)indexPath {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // The Dropbox glyph is a 28pt asset, wider than a symbol's reservation,
    // so every row reserves its width and the labels line up.
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    BOOL action = NO;
    UIImage *dropboxGlyph = [UIImage imageNamed:@"dropbox-glyph"];
    switch ([self rootRowAtIndexPath:indexPath]) {
        case VibeBrowserRootRowDevice:
            content.text = [SearchFolderStore displayNameForFolderURL:SearchFolderStore.containerDocumentsURL];
            content.image = [UIImage systemImageNamed:
                    UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"];
            break;
        case VibeBrowserRootRowDropbox:
            content.text = VibeNotLocalized(@"Dropbox");
            content.secondaryText = DropboxMirror.shared.client.accountName;
            content.image = dropboxGlyph;
            break;
        case VibeBrowserRootRowRecents:
            content.text = STR_BROWSER_RECENTS;
            content.image = [UIImage systemImageNamed:@"clock"];
            break;
        case VibeBrowserRootRowLocation:
            content.text = [SearchFolderStore displayNameForFolderURL:
                    SearchFolderStore.shared.folderURLs[(NSUInteger)indexPath.row]];
            content.image = [UIImage systemImageNamed:@"folder"];
            break;
        case VibeBrowserRootRowConnectDropbox:
            content.text = STR_SETTINGS_DROPBOX_CONNECT;
            content.image = dropboxGlyph;
            action = YES;
            break;
        case VibeBrowserRootRowAddFolder:
            content.text = STR_SETTINGS_SEARCH_FOLDERS_ADD;
            content.image = [UIImage systemImageNamed:@"folder.badge.plus"];
            action = YES;
            break;
        case VibeBrowserRootRowBrowseFiles:
            content.text = STR_BROWSER_OTHER_FILES;
            content.image = [UIImage systemImageNamed:@"doc.badge.ellipsis"];
            action = YES;
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

// A file plays alone and a folder opens, here as in Search and Recents; the
// long press has Play in Folder.
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
        [self openURLs:@[url] inFolder:NO];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self refreshBarItems];
    }
}

- (void)selectSourceAtIndexPath:(NSIndexPath *)indexPath {
    switch ([self rootRowAtIndexPath:indexPath]) {
        case VibeBrowserRootRowDevice:
            [self pushDirectory:SearchFolderStore.containerDocumentsURL];
            return;
        case VibeBrowserRootRowDropbox:
            if (DropboxMirror.shared.accountURL) {
                [self pushDirectory:DropboxMirror.shared.accountURL];
            }
            return;
        case VibeBrowserRootRowRecents:
            [self.navigationController pushViewController:[[RecentsViewController alloc] initWithPlayback:_playback
                                                                                                appending:_appending]
                                                 animated:YES];
            return;
        case VibeBrowserRootRowLocation:
            [self pushDirectory:SearchFolderStore.shared.folderURLs[(NSUInteger)indexPath.row]];
            return;
        case VibeBrowserRootRowConnectDropbox:
            [self connectDropbox];
            return;
        case VibeBrowserRootRowAddFolder:
            [self presentPickerForLocation:YES];
            return;
        case VibeBrowserRootRowBrowseFiles:
            [self presentPickerForLocation:NO];
            return;
    }
}

// A sign-in that lands goes straight into the account: the row was tapped to
// get there.
- (void)connectDropbox {
    __weak BrowserViewController *weakSelf = self;
    [DropboxMirror.shared.client signInWithPresentationAnchor:self.view.window completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
                VibePresentAlert(strongSelf, VibeNotLocalized(@"Dropbox"), STR_SETTINGS_DROPBOX_CONNECT_FAILED);
            }
            else if (DropboxMirror.shared.accountURL
                    && strongSelf.navigationController.topViewController == strongSelf) {
                [strongSelf pushDirectory:DropboxMirror.shared.accountURL];
            }
        });
    }];
}

#pragma mark - Row actions

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !self.isRoot || [self rootRowAtIndexPath:indexPath] == VibeBrowserRootRowLocation;
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
        [weakSelf liftRowsAtIndexPaths:@[indexPath]];
        [weakSelf addURLs:@[url]];
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
    if (tableView.isEditing) {
        return nil;
    }
    __weak BrowserViewController *weakSelf = self;
    if (self.isRoot) {
        // The swipe's Delete, where a long press finds it too.
        if ([self rootRowAtIndexPath:indexPath] != VibeBrowserRootRowLocation) {
            return nil;
        }
        NSURL *location = SearchFolderStore.shared.folderURLs[(NSUInteger)indexPath.row];
        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:nil
                                                        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIAction *remove = VibeMenuAction(STR_BROWSER_REMOVE_LOCATION, @"minus.circle", ^{
                // By URL: the list can move while the menu is up.
                NSUInteger index = [SearchFolderStore.shared.folderURLs indexOfObject:location];
                if (index != NSNotFound) {
                    [SearchFolderStore.shared removeFolderAtIndex:index];
                }
            });
            remove.attributes = UIMenuElementAttributesDestructive;
            return [UIMenu menuWithChildren:@[remove]];
        }];
    }
    NSURL *url = [self itemAtIndexPath:indexPath];
    if (!url) {
        return nil;
    }
    BOOL folder = indexPath.section == VibeBrowserSectionFolders;
    BOOL appendingSheet = _appending;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (!appendingSheet) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
                [weakSelf openURLs:@[url] inFolder:NO];
            })];
            if (!folder) {
                [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
                    [weakSelf openURLs:@[url] inFolder:YES];
                })];
            }
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf liftRowsAtIndexPaths:@[indexPath]];
            [weakSelf addURLs:@[url]];
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
        // One picked file expands to its folder, as it always has.
        [self openURLs:urls inFolder:YES];
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
    self.navigationItem.prompt = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : nil;
    // The add sheet adds; it is no place to manage the list, and its bar
    // carries the way out instead.
    if (_appending) {
        self.navigationItem.rightBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                              target:self
                                                              action:@selector(dismissSheet)];
        return;
    }
    // A menu, so one stray tap cannot empty the list.
    __weak RecentsViewController *weakSelf = self;
    UIAction *clear = [UIAction actionWithTitle:STR_BROWSER_RECENTS_CLEAR_CONFIRM
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(UIAction *action) {
        [weakSelf clearRecents];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:STR_BROWSER_RECENTS_CLEAR
                                              menu:[UIMenu menuWithChildren:@[clear]]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadItems];
}

- (void)dismissSheet {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearRecents {
    [_playback clearRecentItems];
    [self reloadItems];
}

- (void)reloadItems {
    _items = _playback.recentItems;
    [self.tableView reloadData];
    // Absent, not disabled, with nothing to clear.
    self.navigationItem.rightBarButtonItem.hidden = !_appending && _items.count == 0;
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
    // The folder's name as recorded with the item: the path can outlive the
    // container it names, and then says nothing a user would recognize.
    content.secondaryText = item[@"location"];
    VibeApplyFileNameStyle(content);
    content.imageProperties.maximumSize = CGSizeMake(40, 40);
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    content.imageProperties.reservedLayoutSize = CGSizeMake(VibeFileTileSide, VibeFileTileSide);
    if ([item[@"folder"] boolValue]) {
        content.image = [UIImage systemImageNamed:@"folder"];
    }
    else {
        BOOL sheet = [PlaylistFile isCueExtension:[item[@"path"] pathExtension].lowercaseString];
        content.image = VibeFileTileImage(sheet ? @"music.note.list" : @"waveform");
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    // A folder opens in the browser, as a folder row does there; its long
    // press plays it.
    if ([item[@"folder"] boolValue]) {
        [self showFolderOfItem:item];
        return;
    }
    [self openItem:item appending:_appending inFolder:NO];
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
                [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
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
    NSString *name = [item[@"path"] lastPathComponent];
    __weak RecentsViewController *weakSelf = self;
    [playback resolveRecentItem:item completion:^(NSURL *url) {
        if (!url) {
            [weakSelf showUnavailableAlertForName:name];
        }
        else if (appending) {
            [playback addURLs:@[url] token:token];
        }
        else {
            RecentsViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [BrowserViewController confirmReplacingPlaylistOf:playback from:strongSelf
                                                  openingURLs:@[url] inFolder:inFolder];
        }
    }];
    if (_appending) {
        [self dismissSheet];
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
            [root showDirectory:folder ? url : url.URLByDeletingLastPathComponent
                   highlighting:folder ? nil : url];
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
