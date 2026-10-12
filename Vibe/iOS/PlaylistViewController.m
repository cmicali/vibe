//
//  PlaylistViewController.m
//  Vibe (iOS)
//

#import "PlaylistViewController.h"

#import "AudioTrack.h"
#import "BrowserViewController.h"
#import "AudioTrackMetadata.h"
#import "CloudTransferRegistry.h"
#import "EqualizerIndicatorView.h"
#import "FavoritesStore.h"
#import "FileRow.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "PlaylistTrackCell.h"
#import "SettingsViewController.h"
#import "VibeStrings.h"

static NSString *const kTrackCellIdentifier = @"track";

#pragma mark - The screen

@interface PlaylistViewController () <PlaybackObserver, CloudTransferRegistryObserver>
@end

@implementation PlaylistViewController {
    PlaybackController *_playback;
    Playlist           *_playlist;
    // Changes what the empty state says until the next open finds audio.
    BOOL               _lastPickWasEmpty;
    // Appearance covers tabs and pushes; the root's surface fact covers the
    // card, which moves over this view without an appearance transition.
    BOOL               _viewPresentationVisible;
    BOOL               _equalizerSurfaceVisible;
    // The add sheet's browser, which this screen's exposure exposes.
    __weak BrowserViewController *_addSheet;
    // A hidden track change, parked at once on the next reveal.
    NSUInteger         _pendingScrollIndex;
    UIBarButtonItem    *_settingsItem;
    UIBarButtonItem    *_addItem;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
        _pendingScrollIndex = NSNotFound;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Clear Playlist alone in a destructive inline group, as the Favorites
    // long-press menu builds Remove.
    __weak PlaylistViewController *weakSelf = self;
    UIAction *settings = [UIAction actionWithTitle:STR_SETTINGS_TITLE
                                             image:[UIImage systemImageNamed:@"gearshape"]
                                        identifier:nil
                                           handler:^(UIAction *action) {
        [weakSelf settingsTapped];
    }];
    UIAction *clear = [UIAction actionWithTitle:STR_MENU_PLAYLIST_CLEAR
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(UIAction *action) {
        [weakSelf clearTapped];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    UIMenu *destructive = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:@[clear]];
    _settingsItem =
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                              menu:[UIMenu menuWithTitle:@""
                                                               children:@[settings, destructive]]];
    _settingsItem.accessibilityLabel = STR_A11Y_PLAYLIST_MENU;
    _addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(addTapped)];
    _addItem.accessibilityLabel = STR_MENU_CONTEXT_ADD_TO_PLAYLIST;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = kEstimatedRowHeight;
    // The rule starts at the title.
    self.tableView.separatorInset =
            UIEdgeInsetsMake(0, 12 + kNumberColumnWidth + 8 + kFileTileSide + kArtTextGap, 0, 0);
    [self.tableView registerClass:PlaylistTrackCell.class forCellReuseIdentifier:kTrackCellIdentifier];

    [_playback addObserver:self];
    [CloudTransferRegistry.sharedRegistry addObserver:self];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    // An unstar elsewhere and the star's own asynchronous add both arrive here.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(refreshChrome)
                                               name:VibeFavoritesDidChangeNotification
                                             object:nil];
    [self refreshChrome];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    // Visible rows only: willDisplayCell re-renders a prepared cell.
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        NSUInteger index = (NSUInteger)path.row;
        if (index < _playlist.count &&
            [_playlist trackAtIndex:index].metadata == notification.object) {
            [self refreshVisibleRowAtIndex:index];
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self syncCurrentEqualizerActivity];
    [self applyPendingTrackScrollIfVisible];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // At the start of a transition; a cancelled one comes back through
    // viewWillAppear:.
    _viewPresentationVisible = NO;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _viewPresentationVisible = NO;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self syncCurrentEqualizerActivity];
}

- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    if (_equalizerSurfaceVisible == equalizerSurfaceVisible) {
        return;
    }
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    _addSheet.equalizerSurfaceVisible = equalizerSurfaceVisible;
    [self syncCurrentEqualizerActivity];
    [self applyPendingTrackScrollIfVisible];
}

- (BOOL)equalizerSurfaceVisible {
    return _equalizerSurfaceVisible;
}

- (BOOL)isSurfaceMateriallyVisible {
    return _viewPresentationVisible && _equalizerSurfaceVisible;
}

- (void)applyPendingTrackScrollIfVisible {
    if (![self isSurfaceMateriallyVisible] || _pendingScrollIndex == NSNotFound) {
        return;
    }
    NSUInteger index = _pendingScrollIndex;
    _pendingScrollIndex = NSNotFound;
    if (index < _playlist.count) {
        [self.tableView scrollToRowAtIndexPath:
                [NSIndexPath indexPathForRow:(NSInteger)index inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone
                                      animated:NO];
    }
}

// The Files tab's browser as a sheet in which every action appends.
- (void)addTapped {
    BrowserViewController *browser = [[BrowserViewController alloc] initWithPlayback:_playback
                                                                        directoryURL:nil
                                                                           appending:YES];
    browser.equalizerSurfaceVisible = _equalizerSurfaceVisible;
    _addSheet = browser;
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:browser]
                       animated:YES
                     completion:nil];
}

// The Files tab, not the modal picker: it carries our row actions and leaves
// the user somewhere to keep looking.
- (void)openTapped {
    if (_openFilesHandler) {
        _openFilesHandler();
    }
}

// No confirmation: nothing leaves the disk, and reopening rebuilds it.
- (void)clearTapped {
    [_playback clearPlaylist];
}

// Pushed, not presented, so the strip and the card stay up.
- (void)settingsTapped {
    [self.navigationController pushViewController:[[SettingsViewController alloc] initWithPlayback:_playback]
                                         animated:YES];
}

// Title, star and empty state all follow what is open.
- (void)refreshChrome {
    // Not self.title, which is also the tab's title.
    self.navigationItem.title = _playback.folderDisplayName ?: STR_TAB_PLAYLIST;
    [self refreshBarButtons];
    if (_playlist.count > 0) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    UIContentUnavailableConfiguration *empty =
            [UIContentUnavailableConfiguration emptyConfiguration];
    empty.image = [UIImage systemImageNamed:@"music.note.list"];
    empty.text = STR_LABEL_EMPTY_TITLE;
    empty.secondaryText = _lastPickWasEmpty ? STR_ERROR_FOLDER_EMPTY : STR_LABEL_EMPTY_MESSAGE;
    UIButtonConfiguration *button = [UIButtonConfiguration borderedProminentButtonConfiguration];
    button.title = STR_BUTTON_OPEN;
    button.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    empty.button = button;
    __weak PlaylistViewController *weakSelf = self;
    empty.buttonProperties.primaryAction =
            [UIAction actionWithHandler:^(__kindof UIAction *action) {
        [weakSelf openTapped];
    }];
    self.contentUnavailableConfiguration = empty;
}

#pragma mark - The star

// The star and the plus are absent, not disabled, when there is nothing for
// them to act on; the empty state's Open owns the empty playlist. The plus is
// leading: three trailing items crowd the large title.
- (void)refreshBarButtons {
    self.navigationItem.leftBarButtonItem = _playlist.count > 0 ? _addItem : nil;
    NSURL *folderURL = _playback.folderURL;
    if (!folderURL) {
        self.navigationItem.rightBarButtonItems = @[_settingsItem];
        return;
    }
    BOOL favorited = [FavoritesStore.shared containsFolderURL:folderURL];
    UIBarButtonItem *star = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:favorited ? @"star.fill" : @"star"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(favoriteTapped)];
    star.accessibilityLabel = favorited ? STR_MENU_CONTEXT_REMOVE_FAVORITE : STR_A11Y_ADD_FAVORITE;
    self.navigationItem.rightBarButtonItems = @[_settingsItem, star];
}

// The star fills when the mint lands, never on the tap: a row without a
// bookmark cannot be opened. A second tap needs no guard; addFolderURL: dedupes.
- (void)favoriteTapped {
    NSURL *folderURL = _playback.folderURL;
    if (!folderURL) {
        return;
    }
    if ([FavoritesStore.shared containsFolderURL:folderURL]) {
        [FavoritesStore.shared removeFolderURL:folderURL];
        return;
    }
    [_playback bookmarkOpenFolderWithCompletion:^(NSURL *url, NSData *bookmark) {
        if (url && bookmark) {
            [FavoritesStore.shared addFolderURL:url bookmark:bookmark];
        }
    }];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PlaylistTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:kTrackCellIdentifier
                                                              forIndexPath:indexPath];
    NSUInteger index = (NSUInteger)indexPath.row;
    BOOL playing = index == _playlist.currentIndex && _playlist.count > 0;
    cell.levelSource = _playback;
    [cell renderTrack:[_playlist trackAtIndex:index]
               number:index + 1
              playing:playing];
    [self syncLoadingForCell:cell trackIndex:index];
    [self syncEqualizerActivityForCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:PlaylistTrackCell.class]) {
        // TRAP: UIKit displays a prepared cell without re-running
        // cellForRowAtIndexPath:, and the thumbnail and metadata refreshes
        // repaint only visible rows, so a prepared cell can arrive stale.
        // Re-render here; the art read is a non-blocking cache lookup.
        NSUInteger index = (NSUInteger)indexPath.row;
        if (index < _playlist.count) {
            [(PlaylistTrackCell *)cell renderTrack:[_playlist trackAtIndex:index]
                                            number:index + 1
                                           playing:index == _playlist.currentIndex];
            [self syncLoadingForCell:(PlaylistTrackCell *)cell trackIndex:index];
        }
        [self syncEqualizerActivityForCell:(PlaylistTrackCell *)cell];
    }
}

- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:PlaylistTrackCell.class]) {
        PlaylistTrackCell *trackCell = (PlaylistTrackCell *)cell;
        trackCell.equalizerPresentationVisible = NO;
        trackCell.equalizerAudioOutputActive = NO;
        trackCell.loading = NO;
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self syncCurrentEqualizerActivity];
}

- (BOOL)isCellMateriallyVisible:(PlaylistTrackCell *)cell {
    return _equalizerSurfaceVisible && _viewPresentationVisible && [cell vibeIsInViewportOfTableView:self.tableView];
}

- (void)syncEqualizerActivityForCell:(PlaylistTrackCell *)cell {
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    BOOL current = path && _playlist.count > 0
            && (NSUInteger)path.row == _playlist.currentIndex;
    // A hidden equalizer behind the loading bar must not hold a poller.
    BOOL eligible = current && !cell.isLoading;
    cell.equalizerAudioOutputActive = eligible && _playback.audioOutputActive;
    cell.equalizerPresentationVisible = eligible && [self isCellMateriallyVisible:cell];
}

- (void)syncLoadingForCell:(PlaylistTrackCell *)cell trackIndex:(NSUInteger)index {
    AudioTrack *track = index < _playlist.count ? [_playlist trackAtIndex:index] : nil;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    BOOL loading = track.url != nil && [registry isTransferringURL:track.url];
    cell.loading = loading;
    cell.loadingProgress = loading ? [registry progressForURL:track.url] : -1;
}

// In place, never a reload, which would rebuild the playing row's indicator
// and disturb its demand balancing.
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if (![cell isKindOfClass:PlaylistTrackCell.class]) {
            continue;
        }
        NSIndexPath *path = [self.tableView indexPathForCell:cell];
        if (!path) {
            continue;
        }
        [self syncLoadingForCell:(PlaylistTrackCell *)cell
                      trackIndex:(NSUInteger)path.row];
        [self syncEqualizerActivityForCell:(PlaylistTrackCell *)cell];
    }
}

- (void)syncCurrentEqualizerActivity {
    if (_playlist.currentIndex >= _playlist.count) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)_playlist.currentIndex
                                           inSection:0];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if ([cell isKindOfClass:PlaylistTrackCell.class]) {
        [self syncEqualizerActivityForCell:(PlaylistTrackCell *)cell];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_playback selectTrackAtIndex:(NSUInteger)indexPath.row];
}

- (void)refreshVisibleRowAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
    PlaylistTrackCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (!cell) {
        return;
    }
    BOOL playing = index == _playlist.currentIndex;
    BOOL heightMoved = [cell renderTrack:[_playlist trackAtIndex:index]
                                  number:index + 1
                                 playing:playing];
    [self syncEqualizerActivityForCell:cell];
    // TRAP: rendering in place does NOT re-measure an automatic-dimension row.
    // An artist line arriving with metadata outgrows the row at accessibility
    // sizes; the empty update pass re-measures it.
    if (heightMoved) {
        [self.tableView performBatchUpdates:nil completion:nil];
    }
}

#pragma mark - PlaybackObserver

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    _lastPickWasEmpty = NO;
    _pendingScrollIndex = NSNotFound;
    [self.tableView reloadData];
    [self refreshChrome];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self.tableView reloadData];
    [self refreshChrome];
}

- (void)playback:(PlaybackController *)playback didReplaceTrackAtIndex:(NSUInteger)index {
    [self refreshVisibleRowAtIndex:index];
}

- (void)playback:(PlaybackController *)playback
        didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex {
    [self refreshVisibleRowAtIndex:previousIndex];
    [self refreshVisibleRowAtIndex:playback.currentIndex];
    // Under shuffle the list holds still, rather than chase a play order that
    // jumps across it.
    if (_playlist.shuffleEnabled) {
        _pendingScrollIndex = NSNotFound;
        return;
    }
    // Hidden, keep only the newest destination: unseen animated table work
    // competes with the surface in front.
    if (playback.currentIndex < _playlist.count) {
        if ([self isSurfaceMateriallyVisible]) {
            _pendingScrollIndex = NSNotFound;
            [self.tableView scrollToRowAtIndexPath:
                    [NSIndexPath indexPathForRow:(NSInteger)playback.currentIndex inSection:0]
                                  atScrollPosition:UITableViewScrollPositionNone
                                          animated:YES];
        }
        else {
            _pendingScrollIndex = playback.currentIndex;
        }
    }
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self refreshVisibleRowAtIndex:playback.currentIndex];
}

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row >= 0) {
        [self refreshVisibleRowAtIndex:(NSUInteger)row];
    }
}

- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback {
    if (playback.playlist.count > 0) {
        return;   // the playlist stands, and says nothing of the pick
    }
    _lastPickWasEmpty = YES;
    [self refreshChrome];
}

- (void)playbackHasNothingToRestore:(PlaybackController *)playback {
    [self refreshChrome];
}

@end
