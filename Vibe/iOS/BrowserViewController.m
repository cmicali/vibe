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
#import "EqualizerIndicatorView.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "LinkStore.h"
#import "NSURLUtil.h"
#import "PlaybackController.h"
#import "PlaylistFile.h"
#import "SearchFolderStore.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeBrowserSection) {
    VibeBrowserSectionFolders = 0,
    VibeBrowserSectionFiles,
    VibeBrowserSectionCount,
};

static NSString *const kSourceCellIdentifier = @"source";
static NSString *const kActionCellIdentifier = @"action";
static NSString *const kItemCellIdentifier = @"item";
static NSString *const kPasteCellIdentifier = @"paste";

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
// The system's Paste control, in the paste row and in Open URL's sheet.
static const CGSize kPasteControlSize = {112, 36};

@interface BrowserViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating, PlaybackObserver,
        AudioTrackMetadataCacheDelegate, UIAdaptivePresentationControllerDelegate, UITextViewDelegate>
@end

// Every file and folder played or added, newest first (FolderSession). A file
// plays alone, as a search hit does; a folder opens in the browser. Its own
// screen rather than a browser mode: it lists no directory, and every one of
// the browser's directory branches would need a third arm.
@interface RecentsViewController : UITableViewController <PlaybackObserver>
- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending;
@end

void VibePresentAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

UIViewController *VibeTopmostPresenter(UIViewController *root) {
    UIViewController *presenter = root;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    return presenter;
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

void VibeApplyRowContent(UITableViewCell *cell, UIListContentConfiguration *content, BOOL opening) {
    static const NSInteger kOpeningSpinnerTag = 0x6f70656e;
    if (opening) {
        // The slot keeps its place under the spinner: a clear image of its size.
        CGSize size = content.imageProperties.reservedLayoutSize;
        if (size.width <= 0 || size.height <= 0) {
            size = content.image.size;
        }
        content.image = [[[UIGraphicsImageRenderer alloc] initWithSize:size]
                imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
    }
    cell.contentConfiguration = content;
    UIView *spinner = [cell.contentView viewWithTag:kOpeningSpinnerTag];
    UILayoutGuide *slot = [cell.contentView isKindOfClass:UIListContentView.class]
            ? ((UIListContentView *)cell.contentView).imageLayoutGuide : nil;
    if (!opening || !slot) {
        [spinner removeFromSuperview];
        return;
    }
    if (!spinner) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        indicator.tag = kOpeningSpinnerTag;
        indicator.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:indicator];
        [NSLayoutConstraint activateConstraints:@[
            [indicator.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor],
            [indicator.centerYAnchor constraintEqualToAnchor:slot.centerYAnchor],
        ]];
        spinner = indicator;
    }
    // A reload can stop a kept spinner, which then hides.
    [(UIActivityIndicatorView *)spinner startAnimating];
}

BOOL VibeRowIsInViewport(UITableViewCell *cell, UITableView *tableView) {
    UIWindow *window = cell.window;
    if (!window) {
        return NO;
    }
    CGRect rowInTable = [cell convertRect:cell.bounds toView:tableView];
    CGRect visibleInTable = CGRectIntersection(rowInTable, tableView.bounds);
    if (CGRectIsNull(visibleInTable) || CGRectIsEmpty(visibleInTable)) {
        return NO;
    }
    CGRect visibleInWindow = [tableView convertRect:visibleInTable toView:window];
    return !CGRectIsEmpty(CGRectIntersection(visibleInWindow, window.bounds));
}

// Rows past each end of the screen whose art is asked for with the visible ones.
static const NSInteger kArtRowMargin = 20;

// Drawn once, in both appearances: an image asset holding the light and the
// dark tile follows the trait collection by itself, which a single rendered
// image would not.
UIImage *VibeFileTileImage(BOOL playlist) {
    static UIImage *tiles[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGRect bounds = CGRectMake(0, 0, kFileTileSide, kFileTileSide);
        UIImageSymbolConfiguration *configuration =
                [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size];
        for (NSUInteger kind = 0; kind < 2; kind++) {
            NSString *symbol = kind == 1 ? @"music.note.list" : @"waveform";
            UIImage *(^draw)(UIUserInterfaceStyle) = ^UIImage *(UIUserInterfaceStyle style) {
                UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:style];
                UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:configuration]
                        imageWithTintColor:[UIColor.secondaryLabelColor resolvedColorWithTraitCollection:traits]
                             renderingMode:UIImageRenderingModeAlwaysOriginal];
                return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [[UIColor.secondarySystemFillColor resolvedColorWithTraitCollection:traits] setFill];
                    [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:kFileTileCornerRadius] fill];
                    [glyph drawAtPoint:CGPointMake(CGRectGetMidX(bounds) - glyph.size.width / 2,
                                                   CGRectGetMidY(bounds) - glyph.size.height / 2)];
                }];
            };
            UIImage *tile = draw(UIUserInterfaceStyleLight);
            [tile.imageAsset registerImage:draw(UIUserInterfaceStyleDark)
                       withTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:
                                                    UIUserInterfaceStyleDark]];
            tiles[kind] = tile;
        }
    });
    return tiles[playlist ? 1 : 0];
}

void VibeApplyFileIcon(UIListContentConfiguration *content, NSString *name, BOOL folder, UIImage *art) {
    content.imageProperties.reservedLayoutSize = CGSizeMake(kFileTileSide, kFileTileSide);
    content.imageProperties.maximumSize = CGSizeMake(kFileTileSide, kFileTileSide);
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    if (folder) {
        content.image = [UIImage systemImageNamed:@"folder"];
        return;
    }
    content.image = art ?: VibeFileTileImage([PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]);
    content.imageProperties.cornerRadius = kFileTileCornerRadius;
}

// Each pasted item's URL and text, by the pasteboard types a drop is read
// for (VibeDropURLsOfItems). The providers load off main. Completes on main.
static void VibeLoadPastedItems(NSArray<NSItemProvider *> *providers,
                                void (^completion)(NSArray<NSDictionary<NSString *, NSString *> *> *items)) {
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSItemProvider *provider in providers) {
        NSMutableDictionary<NSString *, NSString *> *item = [NSMutableDictionary dictionary];
        [items addObject:item];
        if ([provider canLoadObjectOfClass:NSURL.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSURL.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSURL *url = [(NSObject *)object isKindOfClass:NSURL.class] ? (NSURL *)object : nil;
                @synchronized (item) {
                    if (url) {
                        item[url.isFileURL ? kVibeDropTypeFileURL : kVibeDropTypeURL] = url.absoluteString;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
        if ([provider canLoadObjectOfClass:NSString.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSString.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSString *text = [(NSObject *)object isKindOfClass:NSString.class] ? (NSString *)object : nil;
                @synchronized (item) {
                    if (text) {
                        item[kVibeDropTypeText] = text;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(items);
    });
}

@implementation BrowserViewController {
    PlaybackController *_playback;
    NSURL *_directoryURL;
    BOOL _appending;

    // A directory's whole listing, sorted as the Files app sorts names; which
    // of the files are Dropbox placeholders and each file's size — found with
    // the listing, off main. The M3U playlists lead the files, and a folder
    // holding nothing else has no song for the play button to play.
    NSArray<NSURL *> *_allFolders;
    NSArray<NSURL *> *_allFiles;
    BOOL _hasSongs;
    NSSet<NSURL *> *_placeholders;
    NSDictionary<NSURL *, NSString *> *_fileSizes;
    // The directory's standardized path, so a row's is one append away.
    NSString *_standardizedPath;
    NSString *_title;
    // The playing file's standardized path, for the row that carries the
    // equalizer.
    NSString *_playingPath;
    // Between viewWillAppear: and viewWillDisappear:, for the equalizer; the
    // stack's exposure is the root's equalizerSurfaceVisible.
    BOOL _viewPresentationVisible;
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

    // Album art for the files already on the device, through the app's own
    // metadata pipeline: the stack's one cache (stackArtCache), the
    // listing's local files, and a track per row that has been near the
    // screen.
    AudioTrackMetadataCache *_artCache;
    NSSet<NSURL *> *_localFiles;
    NSMutableDictionary<NSURL *, AudioTrack *> *_artTracks;

    // Which picker is up: a location grant, or a one-off pick.
    BOOL _pickingLocation;
    // A row swipe sets isEditing too; only the Select button's is multi-select.
    BOOL _swipingRow;
    // A subfolder walk is out; a second ask waits for it.
    BOOL _walkingSubfolders;
    // Cancels the link Open URL's sheet or the paste row is resolving. The
    // paste row spins while it is set and no sheet is up.
    dispatch_block_t _cancelLinkResolve;
    // The clipboard's change count when it was last checked, and whether it
    // then probably held a web link. The paste row shows only while it does.
    NSInteger _clipboardChangeCount;
    BOOL _clipboardHasLink;
    // Open URL's sheet while it is up, with its field, Open, and spinner.
    UINavigationController *_linkSheet;
    UITextView *_linkField;
    UIBarButtonItem *_linkOpenItem;
    UIActivityIndicatorView *_linkSpinner;
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
        // TRAP: nothing here may touch the disk. A screen is made on main as
        // a folder opens, and for a provider's folder a stat or a name lookup
        // is IPC that can block.
        _dropboxPath = directoryURL ? [DropboxMirror.shared dropboxPathForURL:directoryURL] : nil;
        _standardizedPath = VibeComparablePath(directoryURL.path);
        _title = directoryURL ? [SearchFolderStore displayNameForFolderURL:directoryURL] : nil;
        _playingPath = VibeComparablePath(playback.currentTrack.url.path);
        _clipboardChangeCount = NSIntegerMin;
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
        // The paste row's control pastes into this screen (pasteItemProviders:).
        self.pasteConfiguration = [[UIPasteConfiguration alloc] initWithAcceptableTypeIdentifiers:
                @[UTTypeURL.identifier, UTTypePlainText.identifier]];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(clipboardMayHaveChanged:)
                                                   name:UIPasteboardChangedNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(clipboardMayHaveChanged:)
                                                   name:UISceneDidActivateNotification
                                                 object:nil];
        // The paste row's control takes its colors resolved (pasteCell).
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class]
                           withAction:@selector(reloadPasteRow)];
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
    if (_holdsScope) {
        [_directoryURL stopAccessingSecurityScopedResource];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    [self syncEqualizer];
    if (self.isRoot) {
        [self refreshClipboardLink];
        [self.tableView reloadData];
        return;
    }
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

#pragma mark - Album art

// One cache for a stack of folders, made by the first screen that needs it:
// each cache opens its own store, which lists the whole metadata cache
// directory when made.
- (AudioTrackMetadataCache *)stackArtCache {
    if (!_artCache) {
        BrowserViewController *root =
                (BrowserViewController *)self.navigationController.viewControllers.firstObject;
        _artCache = [root isKindOfClass:BrowserViewController.class] && root != self
                ? [root stackArtCache] : [[AudioTrackMetadataCache alloc] init];
    }
    return _artCache;
}

// The rows on screen and a margin, not the folder: one merely browsed is not
// parsed whole.
//
// TRAP: only files whose bytes are on the device are asked. A cache miss
// reads the tags from the file, which for a Dropbox placeholder is ranged
// requests and for a provider's dataless file a download: browsing a folder
// costs nothing a row does not say. A file seen before answers from the
// metadata cache without being read at all.
- (void)loadArtForVisibleRows {
    if (_localFiles.count == 0 || !self.viewIfLoaded.window) {
        return;
    }
    [self.tableView layoutIfNeeded];
    NSInteger first = NSIntegerMax;
    NSInteger last = -1;
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.section == VibeBrowserSectionFiles) {
            first = MIN(first, indexPath.row);
            last = MAX(last, indexPath.row);
        }
    }
    if (last < 0) {
        return;
    }
    first = MAX(0, first - kArtRowMargin);
    last = MIN((NSInteger)_files.count - 1, last + kArtRowMargin);
    NSMutableArray<AudioTrack *> *pending = [NSMutableArray array];
    for (NSInteger row = first; row <= last; row++) {
        NSURL *url = _files[(NSUInteger)row];
        if (![_localFiles containsObject:url]) {
            continue;
        }
        AudioTrack *track = _artTracks[url];
        if (!track) {
            if (!_artTracks) {
                _artTracks = [NSMutableDictionary dictionary];
            }
            track = [AudioTrack withURL:url];
            _artTracks[url] = track;
        }
        if (!track.metadata) {
            [pending addObject:track];
        }
    }
    if (pending.count == 0) {
        return;
    }
    AudioTrackMetadataCache *cache = [self stackArtCache];
    cache.delegate = self;
    [cache loadMetadata:pending];
}

- (void)redrawVisibleRowsShowing:(AudioTrackMetadata *)metadata {
    if (!metadata || _artTracks.count == 0 || !self.viewIfLoaded.window) {
        return;
    }
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.section == VibeBrowserSectionFiles && (NSUInteger)indexPath.row < _files.count
                && _artTracks[_files[(NSUInteger)indexPath.row]].metadata == metadata) {
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
    [self redrawVisibleRowsShowing:track.metadata];
}

- (void)artThumbnailDidLoad:(NSNotification *)notification {
    [self redrawVisibleRowsShowing:notification.object];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self loadArtForVisibleRows];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self loadArtForVisibleRows];
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
        NSArray<NSURL *> *playlists = @[];
        NSArray<NSURL *> *files = @[];
        [NSURLUtil listDirectory:directory sortedBy:sort folders:&folders playlists:&playlists audio:&files];
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
            strongSelf->_allFiles = [playlists arrayByAddingObjectsFromArray:files];
            strongSelf->_hasSongs = files.count > 0;
            strongSelf->_placeholders = placeholders;
            strongSelf->_fileSizes = sizes;
            strongSelf->_localFiles = [NSSet setWithArray:local];
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
        _playItem.target = _hasSongs ? self : nil;
        _playItem.action = _hasSongs ? @selector(openDirectory) : NULL;
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
    return [UIMenu menuWithTitle:STR_SETTINGS_FOLDER_SORT_LABEL children:@[choices]];
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
                          inFolder:(BOOL)inFolder
                             token:(uint64_t)token {
    if (urls.count == 0 || ![playback isCurrentReplaceRequest:token]) {
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
    // The question waits on the user, not the disk: its row stops spinning, so
    // the give-up timeout cannot fire over the alert. Replace opens anew.
    [playback endOpeningForReplaceRequest:token];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:STR_PLAYLIST_REPLACE_TITLE
                                                                   message:STR_PLAYLIST_REPLACE_MESSAGE
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_CONFIRM
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { replace(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_ADD
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [playback addURLs:urls];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (dispatch_block_t)openLinkString:(NSString *)string
                replacingPlaylistOf:(PlaybackController *)playback
                               from:(UIViewController *)anchor
                         completion:(void (^)(NSURL *, NSError *))completion {
    uint64_t token = [playback replaceRequestTokenOpening:nil];
    __weak UIWindow *window = anchor.viewIfLoaded.window;
    __weak UIViewController *weakAnchor = anchor;
    return [LinkStore.shared resolveURLString:string completion:^(NSURL *file, NSError *error) {
        // First, so the caller can close what it showed before the replace
        // question goes over the top.
        if (completion) {
            completion(file, error);
        }
        UIViewController *root = window.rootViewController ?: weakAnchor;
        if (file && root) {
            [BrowserViewController confirmReplacingPlaylistOf:playback from:VibeTopmostPresenter(root)
                                                  openingURLs:@[file] inFolder:NO token:token];
        }
    }];
}

#pragma mark - Open URL

// Open URL's sheet, modeled on the mac's window: a field three lines tall that
// wraps, the system's Paste under it, and Cancel and Open. Open is disabled
// while the field is blank. Return is Open and never breaks the line. The
// sheet stays up while the link resolves. Every way it closes cancels that.
- (void)presentLinkSheet {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UITextView *field = [[UITextView alloc] init];
    field.font = font;
    field.adjustsFontForContentSizeCategory = YES;
    field.keyboardType = UIKeyboardTypeURL;
    field.textContentType = UITextContentTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyGo;
    field.backgroundColor = UIColor.tertiarySystemFillColor;
    field.layer.cornerRadius = 10;
    field.textContainerInset = UIEdgeInsetsMake(8, 4, 8, 4);
    field.accessibilityLabel = STR_LINK_PROMPT_TITLE;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;

    UIPasteControlConfiguration *configuration = [[UIPasteControlConfiguration alloc] init];
    configuration.displayMode = UIPasteControlDisplayModeIconAndLabel;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:configuration];
    paste.target = field;
    paste.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.hidesWhenStopped = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;

    UIViewController *content = [[UIViewController alloc] init];
    content.view.backgroundColor = UIColor.systemBackgroundColor;
    content.navigationItem.title = STR_LINK_PROMPT_TITLE;
    content.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelLinkSheet)];
    UIBarButtonItem *open = [[UIBarButtonItem alloc] initWithTitle:STR_BUTTON_OPEN
                                                             style:UIBarButtonItemStyleProminent
                                                            target:self
                                                            action:@selector(openLinkFromSheet)];
    open.enabled = NO;
    content.navigationItem.rightBarButtonItem = open;
    for (UIView *view in @[field, paste, spinner]) {
        [content.view addSubview:view];
    }
    UILayoutGuide *margins = content.view.layoutMarginsGuide;
    CGFloat fieldHeight = ceil(3 * font.lineHeight) + 16;
    [NSLayoutConstraint activateConstraints:@[
        [field.topAnchor constraintEqualToAnchor:content.view.safeAreaLayoutGuide.topAnchor constant:8],
        [field.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [field.heightAnchor constraintEqualToConstant:fieldHeight],
        [paste.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:12],
        [paste.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [paste.widthAnchor constraintEqualToConstant:kPasteControlSize.width],
        [paste.heightAnchor constraintEqualToConstant:kPasteControlSize.height],
        [spinner.centerYAnchor constraintEqualToAnchor:paste.centerYAnchor],
        [spinner.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    ]];

    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:content];
    sheet.modalPresentationStyle = UIModalPresentationFormSheet;
    // The bar, the field, and the Paste row, with a margin under it.
    CGFloat height = 56 + 8 + fieldHeight + 12 + kPasteControlSize.height + 20;
    sheet.preferredContentSize = CGSizeMake(540, height);
    sheet.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent
            customDetentWithIdentifier:nil
                              resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
        return height;
    }]];
    sheet.presentationController.delegate = self;
    _linkSheet = sheet;
    _linkField = field;
    _linkOpenItem = open;
    _linkSpinner = spinner;
    [self presentViewController:sheet animated:YES completion:^{
        [field becomeFirstResponder];
    }];
}

- (void)openLinkFromSheet {
    if (_linkOpenItem.isEnabled) {
        [self openLinkText:_linkField.text];
    }
}

// Cancel: the sheet closes, and a link still resolving stops.
- (void)cancelLinkSheet {
    dispatch_block_t cancel = _cancelLinkResolve;
    [self closeLinkSheetThen:nil];
    if (cancel) {
        cancel();
    }
}

// A swipe down closed the sheet.
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController == _linkSheet) {
        [self cancelLinkSheet];
    }
}

// Closes the sheet, then runs then. With no sheet up, then runs at once.
// TRAP: dismissed by its presenter. Asked of the sheet itself, a dismiss
// closes only an alert it presents.
- (void)closeLinkSheetThen:(nullable dispatch_block_t)then {
    UINavigationController *sheet = _linkSheet;
    _linkSheet = nil;
    _linkField = nil;
    _linkOpenItem = nil;
    _linkSpinner = nil;
    UIViewController *presenter = sheet.presentingViewController;
    if (presenter && !sheet.isBeingDismissed) {
        [presenter dismissViewControllerAnimated:YES completion:then];
    }
    else if (then) {
        then();
    }
}

// Open needs a link in the field. While the link resolves, the field and
// Open are disabled and the spinner turns.
- (void)syncLinkSheet {
    BOOL resolving = _cancelLinkResolve != nil;
    _linkField.editable = !resolving;
    _linkField.textColor = resolving ? UIColor.secondaryLabelColor : UIColor.labelColor;
    _linkOpenItem.enabled = !resolving && !VibeLinkTextIsBlank(_linkField.text);
    if (resolving) {
        [_linkSpinner startAnimating];
    }
    else {
        [_linkSpinner stopAnimating];
    }
}

- (BOOL)textView:(UITextView *)textView
        shouldChangeTextInRanges:(NSArray<NSValue *> *)ranges
                 replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        [self openLinkFromSheet];
        return NO;
    }
    return YES;
}

// A link has no line breaks, so a paste's are dropped. The resolve trims the
// ends.
- (void)textViewDidChange:(UITextView *)textView {
    NSString *text = textView.text;
    NSString *joined = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@""];
    if (joined.length != text.length) {
        textView.text = joined;
    }
    [self syncLinkSheet];
}

// The sheet's Open and the paste row both come here, and only while no link
// resolves. The add sheet takes the Add token before the resolve, as
// Favorites does, and closes once the link is added. A failure closes Open
// URL's sheet first, then shows its alert. Never the inbox road: it does not
// persist.
- (void)openLinkText:(NSString *)text {
    if (VibeLinkTextIsBlank(text) || _cancelLinkResolve) {
        return;
    }
    // Found when the failure lands: the add sheet may be gone by then, and
    // the card may be up.
    __weak UIWindow *window = self.view.window;
    __weak BrowserViewController *weakSelf = self;
    void (^settled)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        NSString *message = error ? [LinkStore messageForError:error brief:NO] : nil;
        dispatch_block_t alert = ^{
            UIViewController *root = window.rootViewController;
            if (message && root) {
                VibePresentAlert(VibeTopmostPresenter(root), STR_LINK_ERROR_TITLE, message);
            }
        };
        BrowserViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            alert();
            return;
        }
        strongSelf->_cancelLinkResolve = nil;
        [strongSelf reloadPasteRow];
        if (file && strongSelf->_appending) {
            // The add sheet takes Open URL's sheet with it.
            strongSelf->_linkSheet = nil;
            [strongSelf dismissSheet];
            return;
        }
        [strongSelf closeLinkSheetThen:alert];
    };
    if (!_appending) {
        _cancelLinkResolve = [BrowserViewController openLinkString:text replacingPlaylistOf:_playback from:self
                                                        completion:settled];
    }
    else {
        PlaybackController *playback = _playback;
        uint64_t token = [playback addRequestToken];
        _cancelLinkResolve = [LinkStore.shared resolveURLString:text completion:^(NSURL *file, NSError *error) {
            if (file) {
                [playback addURLs:@[file] token:token];
            }
            settled(file, error);
        }];
    }
    [self reloadPasteRow];
    [self syncLinkSheet];
}

#pragma mark - The paste row

// Neither question reads the clipboard, so neither raises the paste prompt:
// pattern detection, and whether it holds a URL at all. A change count
// already checked asks nothing.
- (void)refreshClipboardLink {
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSInteger changeCount = pasteboard.changeCount;
    if (!self.isRoot || changeCount == _clipboardChangeCount) {
        return;
    }
    _clipboardChangeCount = changeCount;
    BOOL hasURLs = pasteboard.hasURLs;
    __weak BrowserViewController *weakSelf = self;
    [pasteboard detectPatternsForPatterns:[NSSet setWithObject:UIPasteboardDetectionPatternProbableWebURL]
                        completionHandler:^(NSSet<UIPasteboardDetectionPattern> *patterns, NSError *error) {
        BOOL hasLink = hasURLs || [patterns containsObject:UIPasteboardDetectionPatternProbableWebURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf clipboardHasLink:hasLink changeCount:changeCount];
        });
    }];
}

- (void)clipboardMayHaveChanged:(NSNotification *)notification {
    [self refreshClipboardLink];
}

- (void)clipboardHasLink:(BOOL)hasLink changeCount:(NSInteger)changeCount {
    if (changeCount != _clipboardChangeCount || hasLink == _clipboardHasLink) {
        return;
    }
    _clipboardHasLink = hasLink;
    if (self.viewIfLoaded.window) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeBrowserRootSectionLocations]
                      withRowAnimation:UITableViewRowAnimationFade];
    }
}

// The paste row's control. Its first web link opens as the sheet's Open does.
// Anything else fails as an address that is no link. A paste while a link
// resolves gives that link up, as a second tap on a spinning row does.
- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    dispatch_block_t cancel = _cancelLinkResolve;
    if (cancel) {
        cancel();
        return;
    }
    __weak BrowserViewController *weakSelf = self;
    VibeLoadPastedItems(itemProviders, ^(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
        BrowserViewController *strongSelf = weakSelf;
        NSURL *link = VibePasteLinkOfItems(items);
        if (link) {
            [strongSelf openLinkText:link.absoluteString];
        }
        else if (strongSelf.viewIfLoaded.window) {
            NSError *invalid = [NSError errorWithDomain:VibeLinkErrorDomain code:VibeLinkErrorInvalid userInfo:nil];
            VibePresentAlert(VibeTopmostPresenter(strongSelf), STR_LINK_ERROR_TITLE,
                             [LinkStore messageForError:invalid brief:NO]);
        }
    });
}

- (void)reloadPasteRow {
    NSUInteger row = [[self rootRowsInSection:VibeBrowserRootSectionLocations]
            indexOfObject:@(VibeBrowserRootRowPasteURL)];
    if (self.isRoot && self.viewIfLoaded.window && row != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row
                                                                    inSection:VibeBrowserRootSectionLocations]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
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
    [BrowserViewController confirmReplacingPlaylistOf:_playback from:self openingURLs:urls inFolder:inFolder
                                                token:token];
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
            [strongSelf openURLs:folders inFolder:NO token:token];
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
            [NSURLUtil listDirectory:directory sortedBy:sort folders:&subfolders playlists:NULL audio:&audio];
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
        [sourcePaths addObject:VibeComparablePath(source.path) ?: @""];
    }
    NSString *standardized = VibeComparablePath(directory.path);
    NSUInteger index = VibeSearchFolderCoveringRootIndex(sourcePaths, standardized);
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
        NSUInteger depth = sourcePaths[index].pathComponents.count;
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

// The playing file's row carries the equalizer.
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
    if (!self.isRoot && self.viewIfLoaded.window && ![self isSelecting]) {
        [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - Table

- (NSArray<NSNumber *> *)rootRowsInSection:(NSInteger)section {
    return VibeBrowserRootRows((VibeBrowserRootSection)section, DropboxMirror.shared.client.isLinked,
                               SearchFolderStore.shared.folderURLs.count, _clipboardHasLink);
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
    // An item row keeps its equalizer through reuse and reconfiguration; it
    // decides its own accessory (itemCellAtIndexPath:).
    if (![cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]) {
        cell.accessoryView = nil;
    }
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
    BOOL isFolder = indexPath.section == VibeBrowserSectionFolders;
    VibeApplyFileIcon(content, url.lastPathComponent, isFolder, [_artTracks[url] cachedThumbnail]);
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
    VibeApplyRowContent(cell, content, [path isEqualToString:_playback.openingPath]);
    return cell;
}

#pragma mark - The playing row's equalizer

// The library row's marker, at the library's size; one per playing row.
- (EqualizerIndicatorView *)makeEqualizer {
    EqualizerIndicatorView *equalizer = [[EqualizerIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 16, 14)];
    equalizer.levelSource = _playback;
    return equalizer;
}

- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    if (_equalizerSurfaceVisible == equalizerSurfaceVisible) {
        return;
    }
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:BrowserViewController.class]) {
            [(BrowserViewController *)controller syncEqualizer];
        }
    }
}

// Actual output plus material visibility, the root guarantee's two facts.
- (void)syncEqualizer {
    UIViewController *bottom = self.navigationController.viewControllers.firstObject;
    BOOL surface = _viewPresentationVisible && [bottom isKindOfClass:BrowserViewController.class]
            && ((BrowserViewController *)bottom).equalizerSurfaceVisible;
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell.accessoryView isKindOfClass:EqualizerIndicatorView.class]) {
            EqualizerIndicatorView *equalizer = (EqualizerIndicatorView *)cell.accessoryView;
            equalizer.audioOutputActive = _playback.audioOutputActive;
            equalizer.presentationVisible = surface && VibeRowIsInViewport(cell, self.tableView);
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

- (UITableViewCell *)sourceCellAtIndexPath:(NSIndexPath *)indexPath {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // The Dropbox glyph is a 28pt asset, wider than a symbol's reservation,
    // so every row reserves its width and the labels line up.
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    BOOL action = NO;
    UIImage *dropboxGlyph = [UIImage imageNamed:@"dropbox-glyph"];
    VibeBrowserRootRow row = [self rootRowAtIndexPath:indexPath];
    switch (row) {
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
            content.text = STR_SETTINGS_ADD_FOLDER;
            content.image = [UIImage systemImageNamed:@"folder.badge.plus"];
            action = YES;
            break;
        case VibeBrowserRootRowBrowseFiles:
            content.text = STR_BROWSER_OTHER_FILES;
            content.image = [UIImage systemImageNamed:@"doc.badge.ellipsis"];
            action = YES;
            break;
        case VibeBrowserRootRowOpenURL:
            content.text = STR_BROWSER_OPEN_URL;
            content.image = [UIImage systemImageNamed:@"link"];
            action = YES;
            break;
        case VibeBrowserRootRowPasteURL: {
            content.text = _appending ? STR_BROWSER_PASTE_ADD : STR_BROWSER_PASTE_OPEN;
            content.image = [UIImage systemImageNamed:@"doc.on.clipboard"];
            // The paste row spins while its link resolves; the sheet shows its own.
            UITableViewCell *cell = [self pasteCell];
            VibeApplyRowContent(cell, content, _cancelLinkResolve != nil && _linkSheet == nil);
            return cell;
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
    VibeApplyRowContent(cell, content, NO);
    return cell;
}

// The system's Paste, drawn by the system and never covered, at the row's
// trailing edge. The row's title says what it does. A tap elsewhere on the
// row does nothing: anything but the control would ask to read the clipboard.
- (UITableViewCell *)pasteCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:kPasteCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kPasteCellIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    // TRAP: the system draws the control out of process. It sees no trait
    // collection, so a dynamic color draws its light half, and a translucent
    // one draws as solid gray. The colors are resolved here, and the control
    // is made again for the other appearance.
    UITraitCollection *traits = self.traitCollection;
    if (cell.accessoryView.tag == traits.userInterfaceStyle) {
        return cell;
    }
    // The row's own background and the action rows' tint, so it reads as a
    // row's button.
    UIPasteControlConfiguration *configuration = [[UIPasteControlConfiguration alloc] init];
    configuration.displayMode = UIPasteControlDisplayModeIconAndLabel;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.baseBackgroundColor =
            [UIColor.secondarySystemGroupedBackgroundColor resolvedColorWithTraitCollection:traits];
    configuration.baseForegroundColor =
            [(self.view.tintColor ?: UIColor.systemBlueColor) resolvedColorWithTraitCollection:traits];
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:configuration];
    paste.target = self;
    paste.tag = traits.userInterfaceStyle;
    // It has no size of its own. Its label fits the frame it is given.
    paste.frame = CGRectMake(0, 0, kPasteControlSize.width, kPasteControlSize.height);
    cell.accessoryView = paste;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return !self.isRoot || [self rootRowAtIndexPath:indexPath] != VibeBrowserRootRowPasteURL;
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
    // A second tap on the row still opening gives it up.
    else if ([[_standardizedPath stringByAppendingPathComponent:url.lastPathComponent]
                     isEqualToString:_playback.openingPath]) {
        [_playback cancelOpening];
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
    VibeBrowserRootRow row = [self rootRowAtIndexPath:indexPath];
    switch (row) {
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
        case VibeBrowserRootRowOpenURL:
            // A newer link supersedes the pasted one still resolving.
            if (_cancelLinkResolve) {
                _cancelLinkResolve();
            }
            [self presentLinkSheet];
            return;
        case VibeBrowserRootRowPasteURL:
            // Only its paste control acts.
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
            // An M3U is never a row of its folder, so there is nothing to
            // select in it.
            if (!folder && ![PlaylistFile isM3UExtension:url.pathExtension.lowercaseString]) {
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

#if DEBUG
- (NSDictionary *)debugLinkState {
    NSDictionary *sheet = _linkSheet ? @{
        @"shown": @YES,
        @"text": _linkField.text ?: @"",
        @"resolving": @((BOOL)(_cancelLinkResolve != nil)),
        @"openEnabled": @(_linkOpenItem.isEnabled),
    } : @{@"shown": @NO};
    return @{
        @"pasteRowShown": @([[self rootRowsInSection:VibeBrowserRootSectionLocations]
                containsObject:@(VibeBrowserRootRowPasteURL)]),
        @"pasteRowResolving": @((BOOL)(_cancelLinkResolve != nil && _linkSheet == nil)),
        @"linkSheet": sheet,
    };
}

- (UITextView *)debugLinkField {
    return _linkField;
}
#endif

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
        [playback addObserver:self];
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
            [[UIBarButtonItem alloc] initWithTitle:STR_BUTTON_CLEAR
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
    VibeApplyFileIcon(content, path, [item[@"folder"] boolValue], nil);
    VibeApplyRowContent(cell, content, [VibeComparablePath(path) isEqualToString:_playback.openingPath]);
    return cell;
}

- (void)playbackDidChangeOpening:(PlaybackController *)playback {
    if (self.viewIfLoaded.window) {
        [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                              withRowAnimation:UITableViewRowAnimationNone];
    }
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
    // A second tap on the row still opening gives it up.
    if ([VibeComparablePath(item[@"path"]) isEqualToString:_playback.openingPath]) {
        [_playback cancelOpening];
        return;
    }
    [self openItem:item appending:_appending inFolder:NO];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    BOOL folder = [item[@"folder"] boolValue];
    // A link's folder is the store's, named by a hash and holding the one
    // file: no Play in Folder, no Open Folder.
    BOOL folderActions = ![LinkStore.shared containsURL:[NSURL fileURLWithPath:item[@"path"]]];
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
            if (!folder && folderActions
                    && ![PlaylistFile isM3UExtension:[item[@"path"] pathExtension].lowercaseString]) {
                [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
                    [weakSelf openItem:item appending:NO inFolder:YES];
                })];
            }
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf openItem:item appending:YES inFolder:NO];
        })];
        if (folderActions) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_OPEN_FOLDER, @"folder", ^{
                [weakSelf showFolderOfItem:item];
            })];
        }
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

// The resolve is provider IPC, so the token is taken first: an open the user
// makes while it runs supersedes an Add (FolderSession) and a replace alike.
- (void)openItem:(NSDictionary *)item appending:(BOOL)appending inFolder:(BOOL)inFolder {
    PlaybackController *playback = _playback;
    uint64_t token = appending ? [playback addRequestToken]
                               : [playback replaceRequestTokenOpening:[NSURL fileURLWithPath:item[@"path"]]];
    NSString *name = [item[@"path"] lastPathComponent];
    __weak RecentsViewController *weakSelf = self;
    [playback resolveRecentItem:item completion:^(NSURL *url) {
        if (!url) {
            if (!appending) {
                [playback endOpeningForReplaceRequest:token];
            }
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
                                                  openingURLs:@[url] inFolder:inFolder token:token];
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

