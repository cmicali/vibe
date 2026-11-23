//
//  PlaybackShellHost.m
//  Vibe (iOS)
//

#import "PlaybackShellHostInternal.h"

#import "AppSettings.h"
#import "AudioTrack+TrackRow.h"
#import "AudioTrackMetadata.h"
#import "BrowserRootViewController.h"
#import "CueFolderGrantPrompt.h"
#import "FavoritesViewController.h"
#import "MiniPlayerView.h"
#import "PlaybackBrowserHost.h"
#import "PlaybackController.h"
#import "PlayerScreenRules.h"
#import "PlayerViewController.h"
#import "PlaylistViewController.h"
#import "RootViewController.h"
#import "SearchViewController.h"
#import "UIViewController+Alert.h"
#import "VibePlaylist.h"
#import "VibeStrings.h"

static NSString *const kTabPlaylist = @"playlist";
static NSString *const kTabFavorites = @"favorites";
static NSString *const kTabFiles = @"files";

@interface PlayerViewController (Shell) <RootViewControllerCard>
@end

@implementation PlayerViewController (Shell)
@end

@interface PlaybackShellHost () <PlaybackObserver, PlayerViewControllerDelegate, RootViewControllerDelegate>
@end

@implementation PlaybackShellHost {
    PlaybackController     *_playback;
    RootViewController     *_root;
    PlayerViewController   *_player;
    BrowserRootViewController *_filesController;
    FavoritesViewController *_favorites;
    PlaylistViewController *_playlistScreen;
    SearchViewController   *_searchController;
    CueFolderGrantPrompt   *_cueFolderGrantPrompt;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super init];
    if (self) {
        _playback = playback;
        _cueFolderGrantPrompt = [[CueFolderGrantPrompt alloc] init];
        _player = [[PlayerViewController alloc] initWithPlayback:playback];
        _player.delegate = self;
        _root = [[RootViewController alloc] initWithTabs:[self buildTabs] card:_player];
        _root.delegate = self;
        [_root.miniPlayer setAccessibilityLabelsForExpand:STR_SETTINGS_NOW_PLAYING_SECTION
                                                     play:STR_TRANSPORT_PLAY
                                                    pause:STR_TRANSPORT_PAUSE
                                                     next:STR_TRANSPORT_NEXT];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (RootViewController *)root {
    return _root;
}

- (PlaybackController *)playback {
    return _playback;
}

- (PlayerViewController *)player {
    return _player;
}

- (PlaylistViewController *)playlistScreen {
    return _playlistScreen;
}

- (BrowserRootViewController *)filesBrowser {
    return _filesController;
}

- (FavoritesViewController *)favorites {
    return _favorites;
}

- (SearchViewController *)searchScreen {
    return _searchController;
}

// The card reads no setting itself.
- (void)displaySettingsDidChange {
    [_player reloadSettings];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    if (_playback.displayedTrack.metadata == notification.object) {
        [self refreshMiniPlayer];
    }
}

// Lazy providers, so a tab never visited costs nothing. The Files browser is
// not cheap.
- (NSArray<UITab *> *)buildTabs {
    __weak PlaybackShellHost *weakSelf = self;

    UITab *playlist = [[UITab alloc] initWithTitle:STR_TAB_PLAYLIST
                                             image:[UIImage systemImageNamed:@"music.note.list"]
                                        identifier:kTabPlaylist
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        PlaybackShellHost *host = weakSelf;
        if (!host) {
            return nil;
        }
        PlaylistViewController *playlistScreen =
                [[PlaylistViewController alloc] initWithPlayback:host->_playback];
        host->_playlistScreen = playlistScreen;
        // The empty state's Open; the Playlist tab knows nothing about tabs.
        playlistScreen.openFilesHandler = ^{
            weakSelf.root.selectedTabIdentifier = kTabFiles;
        };
        [host syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:playlistScreen];
    }];

    UITab *favorites = [[UITab alloc] initWithTitle:STR_TAB_FAVORITES
                                              image:[UIImage systemImageNamed:@"star"]
                                         identifier:kTabFavorites
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        PlaybackShellHost *host = weakSelf;
        if (!host) {
            return nil;
        }
        FavoritesViewController *starred =
                [[FavoritesViewController alloc] initWithPlayback:host->_playback];
        host->_favorites = starred;
        starred.showDirectoryHandler = ^(NSURL *directory) {
            [weakSelf showDirectoryInFiles:directory highlighting:nil];
        };
        return [[UINavigationController alloc] initWithRootViewController:starred];
    }];

    UITab *files = [[UITab alloc] initWithTitle:STR_TAB_FILES
                                          image:[UIImage systemImageNamed:@"folder"]
                                     identifier:kTabFiles
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        PlaybackShellHost *host = weakSelf;
        if (!host) {
            return nil;
        }
        BrowserRootViewController *browser = [PlaybackBrowserHost rootWithPlayback:host->_playback appending:NO];
        host->_filesController = browser;
        browser.addedRowsHandler = ^(NSArray<UIView *> *rows) {
            [weakSelf liftAddedRows:rows];
        };
        [host syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:browser];
    }];

    UISearchTab *search = [[UISearchTab alloc] initWithViewControllerProvider:
            ^UIViewController *(__kindof UITab *tab) {
        PlaybackShellHost *host = weakSelf;
        if (!host) {
            return nil;
        }
        SearchViewController *results =
                [[SearchViewController alloc] initWithPlayback:host->_playback];
        host->_searchController = results;
        results.showDirectoryHandler = ^(NSURL *directory, NSURL *file) {
            [weakSelf showDirectoryInFiles:directory highlighting:file];
        };
        [host syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:results];
    }];
    search.automaticallyActivatesSearch = YES;

    return @[playlist, favorites, files, search];
}

// Ask the ivars, never UITab.viewController, whether a tab exists: the getter
// resolves the provider.
- (void)syncTabSurfaces {
    BOOL tabsExposed = _root.tabsExposed;
    NSString *selected = _root.tabs.selectedTab.identifier;
    _playlistScreen.equalizerSurfaceVisible = tabsExposed && [selected isEqualToString:kTabPlaylist];
    _filesController.equalizerSurfaceVisible = tabsExposed && [selected isEqualToString:kTabFiles];
    BOOL searchSelected = [_root.tabs.selectedTab isKindOfClass:UISearchTab.class];
    _searchController.materialSurfaceVisible = tabsExposed && _root.cardAtRest && searchSelected;
}

- (void)refreshMiniPlayer {
    VibeTrackRow *row = VibeMiniPlayerVisible(_playback.screenState) ? _playback.displayedTrack.trackRow : nil;
    [_root setMiniPlayerRow:row playing:_playback.isPlaying];
}

// The stack is built before the tab shows, so the tab arrives on the folder
// rather than on its old screen and then jumping.
- (void)showDirectoryInFiles:(NSURL *)directory highlighting:(NSURL *)file {
    // A tab's controller is built on first ask: one never visited has none yet.
    (void)[_root.tabs tabForIdentifier:kTabFiles].viewController;
    [_filesController showDirectory:directory highlighting:file];
    _root.selectedTabIdentifier = kTabFiles;
}

- (void)bringPlaylistTabForward {
    if (![_root.tabs.selectedTab isKindOfClass:UISearchTab.class]) {
        _root.selectedTabIdentifier = kTabPlaylist;
    }
}

// A sheet or alert keeps the screen as the user left it. Closing it would
// drop what they started. A tab switch under it would leave it over the
// wrong tab.
- (void)showPlaylist {
    if (_root.vibeTopmostPresenter != _root) {
        return;
    }
    [_root minimizeCardAnimated:NO];
    _root.selectedTabIdentifier = kTabPlaylist;
    [_playlistScreen.navigationController popToRootViewControllerAnimated:NO];
}

- (BOOL)getPlaylistTabCenter:(CGPoint *)center {
    return [_root getCenterOfTabWithIdentifier:kTabPlaylist center:center];
}

#pragma mark - RootViewControllerDelegate

// After the card's own registration, so the card hears each event first.
- (void)rootViewControllerDidLoad:(RootViewController *)root {
    [_playback addObserver:self];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(displaySettingsDidChange)
                                               name:VibeDisplaySettingsDidChangeNotification
                                             object:nil];
    [self refreshMiniPlayer];
}

- (BOOL)rootViewControllerCanExpandCard:(RootViewController *)root {
    return _playback.playlist.count > 0;
}

- (void)rootViewControllerDidTapPlayPause:(RootViewController *)root {
    [_playback playPause];
}

- (void)rootViewControllerDidTapNext:(RootViewController *)root {
    [_playback next];
}

// Settings rides the Playlist tab's stack: leaving the tab pops it, so
// coming back shows the playlist, not the screen left open.
- (void)rootViewController:(RootViewController *)root
              didSelectTab:(UITab *)selectedTab
               previousTab:(UITab *)previousTab {
    if (selectedTab != previousTab && [previousTab.identifier isEqualToString:kTabPlaylist]) {
        [_playlistScreen.navigationController popToRootViewControllerAnimated:NO];
    }
}

- (void)rootViewControllerDidChangeExposure:(RootViewController *)root {
    [self syncTabSurfaces];
}

#pragma mark - PlayerViewControllerDelegate

- (void)playerViewControllerDidRequestMinimize:(PlayerViewController *)controller {
    [_root minimizeCardAnimated:YES];
}

- (void)playerViewController:(PlayerViewController *)controller
       didPanWithTranslation:(CGFloat)translation
                    velocity:(CGFloat)velocity
                       state:(UIGestureRecognizerState)state {
    [_root cardDidPanWithTranslation:translation velocity:velocity state:state];
}

#pragma mark - PlaybackObserver

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [self refreshMiniPlayer];
    // An Add onto nothing became an open: the card says so.
    [self settleEveryLiftedRowUnlanded];
}

// Every Add ends here; the oldest lift is its.
- (void)playback:(PlaybackController *)playback didSettleAddLanding:(BOOL)landed {
    if (_liftedRowBatches.count > 0) {
        [self settleLiftedRows:_liftedRowBatches.firstObject landed:landed];
    }
}

// The only place the card presents by itself. The Playlist tab comes forward,
// so minimizing lands on what was opened. Search keeps the selection while
// its field is up. A single file played alone, one track with no folder,
// also keeps its tab, so minimizing lands back in the browser rather than on
// a one-row playlist.
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback {
    if (playback.playlist.count > 1 || playback.folderURL) {
        [self bringPlaylistTabForward];
    }
    [_root expandCardAnimated:YES];
}

// Only the Playlist tab's empty state says a pick found no audio, so the tab
// comes forward only over an empty playlist. An open supersedes every Add in
// flight whatever it found, so their lifted rows settle here as they do on
// a replace that landed.
- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback {
    if (playback.playlist.count == 0) {
        [self bringPlaylistTabForward];
    }
    [self settleEveryLiftedRowUnlanded];
}

- (void)playbackDidCancelOpening:(PlaybackController *)playback {
    [self settleEveryLiftedRowUnlanded];
}

- (void)playback:(PlaybackController *)playback didGiveUpOpeningPath:(NSString *)path {
    [_root.vibeTopmostPresenter vibePresentAlertWithTitle:path.lastPathComponent message:STR_ERROR_OPEN_TOO_SLOW];
}

// "Open in Vibe" can arrive with the card presented.
- (void)playback:(PlaybackController *)playback
        needsFolderOfSheetAtURL:(NSURL *)sheetURL
                      appending:(BOOL)appending {
    [_cueFolderGrantPrompt askForFolderOfSheetAtURL:sheetURL
                                          appending:appending
                                           playback:playback
                                          presenter:_root.vibeTopmostPresenter];
}

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    [self refreshMiniPlayer];
}

- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback {
    [self refreshMiniPlayer];
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self refreshMiniPlayer];
}

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    if ([playback.playlist isCurrentTrack:track]) {
        [self refreshMiniPlayer];
    }
}

@end
