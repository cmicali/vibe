//
//  PlayerViewController.m
//  Vibe (iOS)
//
//  The coordination: the collaborators it owns, the update funnel, the header
//  and empty states, the transport entry points, and the two session
//  delegates. Everything else is a category — see PlayerViewControllerInternal.h
//  for the surface they share.
//

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlayerViewController+NowPlaying.h"
#import "PlayerViewController+Pager.h"
#import "PlayerViewController+PlayerEvents.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DownloadProgressMonitor.h"
#import "PageWaveformCoordinator.h"
#import "SearchViewController.h"
#import "TrackListViewController.h"
#import "TrackPageCell.h"
#import "TrackPageGeometry.h"
#import "UIUpdateTimer.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "VibeWeakProxy.h"
#import "WaveformMidline.h"   // the empty line IS the scrubber's placeholder
#import "WaveformScrubberView.h"

// Fixed, unlike the mac's playhead-speed-scaled rate (Util/UIUpdateMath.h):
// there the timer is what moves the playhead, here the CADisplayLink owns it
// while playing. This tick only feeds the time labels, which change once a
// second, and the Now Playing publish.
static const NSUInteger kUIUpdateHz = 3;

@implementation PlayerViewController {
    // Drives the scrolling waveform at display rate while playing in the
    // foreground; the 3 Hz timer is far too coarse for a moving waveform.
    CADisplayLink           *_scrollLink;

    UIView                  *_emptyLineView;
    NSLayoutConstraint      *_emptyLineCenterY;  // re-aimed per orientation

    // The bottom bar's geometry. The search field is BUILT BUT NOT REACHABLE:
    // search is not shipped yet (see SearchViewController), so the button is
    // hidden and the bar's width is held by a layout guide instead — a hidden
    // control silently defining the layout is how the parked feature came to
    // look shipped.
    UILayoutGuide           *_searchBarGuide;
    UIButton                *_searchBarButton;   // Messages-style glass search bar; hidden
    UIButton                *_folderButton;      // the compose-position circle
    UITapGestureRecognizer  *_emptyStateTap;

    // Weak, like the track list's handle: presentation owns the sheet, and the
    // reference exists only to forward playlist changes while one is up.
    __weak SearchViewController *_searchController;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Forced dark, like the Apple Music and SoundCloud player screens: every
    // label and the waveform must read over arbitrary blurred art.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];

    _playlist = [[Playlist alloc] init];
    _playlist.observer = self;
    _metadataCache = [[AudioTrackMetadataCache alloc] init];
    _metadataCache.delegate = self;
    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCoordinator = [[PageWaveformCoordinator alloc] initWithCache:_waveformCache delegate:self];
    _artHeldPages = [NSMutableIndexSet indexSet];
    _audioSession = [[AudioSessionController alloc] init];
    _audioSession.delegate = self;
    _folderSession = [[FolderSession alloc] init];
    _folderSession.delegate = self;
    _nowPlaying = [[NowPlayingController alloc] initWithDelegate:self];
    // No FX on iOS: nothing surfaces them, so the FX graph segment is never
    // created or attached — the mixer wires straight to the output. A hard
    // NO, not the shared audioFXEnabled setting, so the mac default cannot
    // reach in here.
    _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self];

    __weak PlayerViewController *weakSelf = self;
    _updateTimer = [[UIUpdateTimer alloc] initWithHz:kUIUpdateHz handler:^{
        [weakSelf updatePlaybackUI];
    }];
    _updateTimer.windowVisible = YES;

    _foreground = YES;
    _scrollLink = [CADisplayLink displayLinkWithTarget:[VibeWeakProxy proxyWithTarget:self]
                                              selector:@selector(scrollTick:)];
    // ~1pt/frame of motion gains nothing at 120 Hz; spare ProMotion the work.
    _scrollLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    _scrollLink.paused = YES;
    [_scrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    // In the background the system extrapolates position from the last Now
    // Playing publish, so the 3 Hz tick is pure waste there — the same rule
    // as the mac window's occlusion gate.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(sceneDidEnterBackground)
                   name:UISceneDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(sceneWillEnterForeground)
                   name:UISceneWillEnterForegroundNotification object:nil];

    // No restore here: the scene delegate calls restorePersistedSession or
    // handleOpenURLContexts: once the window is up, so a cold "Open in Vibe"
    // never pays for a restore it immediately replaces.
}

- (void)restorePersistedSession {
    if (![_folderSession restorePersistedFolder]) {
        [self showEmptyState];
    }
}

- (void)sceneDidEnterBackground {
    _updateTimer.windowVisible = NO;
    _foreground = NO;
    [self updateScrollLinkState];
}

- (void)sceneWillEnterForeground {
    _updateTimer.windowVisible = YES;
    _foreground = YES;
    [self updateScrollLinkState];
    [self updatePlaybackUI];
}

// Reachable because the display link holds the weak proxy, not the
// controller; the invalidate releases the link's run-loop registration.
- (void)dealloc {
    [_scrollLink invalidate];
}

#pragma mark - UI construction

- (void)buildUI {
    UIView *root = self.view;

    _pagesLayout = [[UICollectionViewFlowLayout alloc] init];
    _pagesLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    _pagesLayout.minimumLineSpacing = 0;
    _pagesLayout.minimumInteritemSpacing = 0;
    _pagesView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                    collectionViewLayout:_pagesLayout];
    _pagesView.pagingEnabled = YES;
    _pagesView.showsHorizontalScrollIndicator = NO;
    _pagesView.allowsSelection = NO;
    // Photos-style edge give: pulling past the first or last page reveals the
    // backdrop and springs back. alwaysBounce keeps the pull alive on a
    // one-track playlist too, where content exactly fills the bounds.
    _pagesView.bounces = YES;
    _pagesView.alwaysBounceHorizontal = YES;
    _pagesView.backgroundColor = [UIColor clearColor];
    // What an edge pull (and the empty state) reveals behind the pages: the
    // record texture, full-bleed. backgroundView pins it behind the cells
    // without scrolling.
    UIImageView *backdrop = [[UIImageView alloc]
            initWithImage:[UIImage imageNamed:@"record-bg"]];
    backdrop.contentMode = UIViewContentModeScaleAspectFill;
    backdrop.clipsToBounds = YES;
    _pagesView.backgroundView = backdrop;
    // Pages must be exactly screen-sized; safe-area adjustment would shrink
    // the content and break the paging math.
    _pagesView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _pagesView.dataSource = self;
    _pagesView.delegate = self;
    [_pagesView registerClass:TrackPageCell.class
        forCellWithReuseIdentifier:TrackPageCell.reuseIdentifier];
    _pagesView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_pagesView];

    _emptyHintLabel = [[UILabel alloc] init];
    _emptyHintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    _emptyHintLabel.adjustsFontForContentSizeCategory = YES;
    _emptyHintLabel.textColor = [UIColor secondaryLabelColor];
    _emptyHintLabel.textAlignment = NSTextAlignmentCenter;
    _emptyHintLabel.numberOfLines = 0;
    _emptyHintLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _emptyHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_emptyHintLabel];

    // The empty state's midline — the mac view's placeholder line, drawn in
    // the chrome because with no tracks there are no page cells to host it.
    // It IS the scrubber's own placeholder, so it takes the shared metrics
    // rather than restating them; the screen is forced dark, hence white.
    _emptyLineView = [[UIView alloc] init];
    _emptyLineView.backgroundColor =
            [UIColor.whiteColor colorWithAlphaComponent:kVibeInertMidlineAlpha];
    _emptyLineView.hidden = YES;
    _emptyLineView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_emptyLineView];

    // The waveform, time labels, and play glyph live in the page cells; the
    // bindings are established as cells appear. Next lives in the page
    // swipe, the track list, and the lock screen.

    // The Messages-style bottom bar: a wide glass search field, and the
    // folder button in the compose position beside it.
    UIButtonConfiguration *searchConfig = [UIButtonConfiguration glassButtonConfiguration];
    searchConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    searchConfig.image = [UIImage systemImageNamed:@"magnifyingglass"];
    searchConfig.title = STR_LABEL_SEARCH;
    searchConfig.imagePadding = 8;
    searchConfig.baseForegroundColor = [UIColor secondaryLabelColor];
    searchConfig.contentInsets = NSDirectionalEdgeInsetsMake(14, 18, 14, 18);
    _searchBarButton = [UIButton buttonWithConfiguration:searchConfig primaryAction:nil];
    _searchBarButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _searchBarButton.accessibilityLabel = STR_LABEL_SEARCH;
    [_searchBarButton addTarget:self action:@selector(searchTapped)
               forControlEvents:UIControlEventTouchUpInside];
    _searchBarButton.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBarButton.hidden = YES;  // not shipped yet; searchTapped is unreachable
    [root addSubview:_searchBarButton];

    // The span the search field occupies, held whether or not it is visible,
    // so unhiding the button is the only change shipping search needs.
    _searchBarGuide = [[UILayoutGuide alloc] init];
    [root addLayoutGuide:_searchBarGuide];

    UIButtonConfiguration *folderConfig = [UIButtonConfiguration glassButtonConfiguration];
    folderConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    folderConfig.image = [UIImage systemImageNamed:@"list.bullet"];
    folderConfig.baseForegroundColor = [UIColor labelColor];
    _folderButton = [UIButton buttonWithConfiguration:folderConfig primaryAction:nil];
    _folderButton.accessibilityLabel = STR_A11Y_TOGGLE_PLAYLIST;
    [_folderButton addTarget:self action:@selector(playlistTapped)
            forControlEvents:UIControlEventTouchUpInside];
    _folderButton.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_folderButton];

    // Tap anywhere (off the waveform and the controls) — the art card
    // included: choose a folder when empty, otherwise toggle play/pause —
    // the glyph hides while playing, so the tap IS the pause control.
    _emptyStateTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                             action:@selector(screenTapped)];
    _emptyStateTap.delegate = self;
    [root addGestureRecognizer:_emptyStateTap];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_pagesView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_pagesView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_pagesView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_pagesView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

        [_emptyHintLabel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_emptyHintLabel.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [_emptyHintLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [_emptyHintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

        [_emptyLineView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_emptyLineView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_emptyLineView.heightAnchor constraintEqualToConstant:kVibeMidlineHeight],

        [_searchBarGuide.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_searchBarGuide.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
        [_searchBarGuide.heightAnchor constraintEqualToConstant:52],
        [_searchBarButton.leadingAnchor constraintEqualToAnchor:_searchBarGuide.leadingAnchor],
        [_searchBarButton.trailingAnchor constraintEqualToAnchor:_searchBarGuide.trailingAnchor],
        [_searchBarButton.topAnchor constraintEqualToAnchor:_searchBarGuide.topAnchor],
        [_searchBarButton.bottomAnchor constraintEqualToAnchor:_searchBarGuide.bottomAnchor],
        [_folderButton.leadingAnchor constraintEqualToAnchor:_searchBarGuide.trailingAnchor constant:12],
        [_folderButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_folderButton.centerYAnchor constraintEqualToAnchor:_searchBarGuide.centerYAnchor],
        [_folderButton.widthAnchor constraintEqualToConstant:52],
        [_folderButton.heightAnchor constraintEqualToConstant:52],
    ]];

    _emptyLineCenterY = [_emptyLineView.centerYAnchor constraintEqualToAnchor:safe.bottomAnchor];
    _emptyLineCenterY.active = YES;
    [self aimEmptyLine];
}

// Keeps the empty-state line on the nominal waveform midline of whichever
// cell layout the current orientation uses.
- (void)aimEmptyLine {
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    _emptyLineCenterY.constant = landscape
            ? -(kTrackPageWaveformBottomInsetLandscape + kTrackPageWaveformHeightLandscape / 2)
            : -(kTrackPageWaveformBottomInset + kTrackPageWaveformHeight / 2);
}

// The at-rest time rendering shared by neighbor pages, a pending track
// start, and a parked track the player has not opened: 0:00 elapsed, the
// full duration once metadata knows it.
+ (void)renderRestingTimesForTrack:(AudioTrack *)track
                           elapsed:(UILabel *)elapsed
                         remaining:(UILabel *)remaining {
    BOOL known = track.duration > 0;
    elapsed.text = known
            ? [[Formatters sharedInstance] durationStringFromTimeInterval:0]
            : STR_LABEL_TIME_UNKNOWN;
    remaining.text = known ? track.durationString : STR_LABEL_TIME_UNKNOWN;
}

- (void)renderRestingTimesForTrack:(AudioTrack *)track {
    [PlayerViewController renderRestingTimesForTrack:track
                                              elapsed:_elapsedLabel
                                            remaining:_remainingLabel];
}

#pragma mark - Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // The waveforms own horizontal drags and taps for scrubbing, and the
    // controls own their touches; the screen tap applies everywhere else.
    // Class membership, not frames: every page cell carries a waveform view
    // in its own coordinate space.
    for (UIView *view = touch.view; view && view != self.view; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]
                || [view isKindOfClass:[WaveformScrubberView class]]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Display state

// Gathers the rule's inputs, sampling the player once so the whole state
// resolves against one consistent view of it.
- (VibePlayerScreenState)screenState {
    return VibeResolvePlayerScreenState(_playlist.count, _trackStartPending,
                                        _parked, _errorText != nil,
                                        _player.duration);
}

- (AudioTrack *)displayedTrack {
    return VibePlayerScreenDescribesTrack([self screenState]) ? _playlist.currentTrack : nil;
}

#pragma mark - Header rendering

- (void)showEmptyState {
    _emptyHintLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _emptyHintLabel.hidden = NO;
    _emptyLineView.hidden = NO;
    [self updatePlayButton];
}

// The pager owns the header, art, and waveform; rendering the current track
// means refreshing its page and rebinding the live chrome to it.
- (void)renderHeaderForTrack:(AudioTrack *)track {
    _emptyHintLabel.hidden = YES;
    _emptyLineView.hidden = YES;
    // Before the repaint, and from here rather than the currentIndex observer,
    // so a park or a restore that lands on the index already current still
    // moves the window onto it.
    [self refreshArtWindow];
    [self refreshPageAtIndex:_playlist.currentIndex];
    TrackPageCell *cell = [self cellAtIndex:_playlist.currentIndex];
    if (cell) {
        [self bindChromeToCell:cell];
    }
    else {
        // A far jump: the target page has no live cell yet. Drop the bindings
        // rather than keep the old page's — the incoming track's rest state
        // and loading shimmer must not write into the outgoing track's still-
        // visible cell during the scroll. willDisplayCell rebinds on arrival.
        _boundPage = nil;
        _waveformView = nil;
        _elapsedLabel = nil;
        _remainingLabel = nil;
        _playPauseButton = nil;
    }
}

- (void)updatePlayButton {
    [_boundPage setGlyphPlaying:_player.isPlaying];
    [self updateChrome];
}

// Playing hides the play glyph — a screen tap pauses — and pausing (parked
// and stopped included) brings it back between the time labels. The empty
// state shows no glyph either: there is nothing to play until a folder is
// chosen.
- (CGFloat)chromeAlpha {
    return (_player.isPlaying || [self screenState] == VibePlayerScreenStateEmpty) ? 0 : 1;
}

- (void)updateChrome {
    CGFloat buttonAlpha = [self chromeAlpha];
    if (_playPauseButton.alpha == buttonAlpha) {
        return;
    }
    [UIView animateWithDuration:0.3 animations:^{
        self->_playPauseButton.alpha = buttonAlpha;
    }];
}

// Paused unless the playhead is actually moving where someone can see it. A
// page swipe counts as nowhere: the waveform translating a fraction of a pixel
// under a page that is itself sliding across the screen is invisible, and the
// frames it costs are exactly the ones the swipe needs.
- (void)updateScrollLinkState {
    _scrollLink.paused = !(_player.isPlaying && _foreground && !_pagerScrolling);
}

- (void)scrollTick:(CADisplayLink *)link {
    if (self.presentedViewController) {
        // A sheet covers the waveform strip. The per-frame translation of the
        // multi-screen layer tree is invisible waste, and it competes with the
        // sheet + keyboard presentation for exactly the frames that stutter on
        // device; the 3 Hz timer keeps progress near-current for the reveal.
        return;
    }
    if (_waveformView.isScrubbing) {
        return;
    }
    if ([self screenState] == VibePlayerScreenStateLoading) {
        _waveformView.progress = 0;
        return;
    }
    if (_seekInFlight) {
        _waveformView.progress = _pendingSeekProgress;
        return;
    }
    NSTimeInterval duration = _player.duration;  // non-blocking, like position
    if (duration > 0) {
        _waveformView.progress = _player.position / duration;
    }
}

- (void)updatePlaybackUI {
    if (VibePlayerScreenRendersRestingTimes([self screenState])) {
        // The current track at rest — the neighbor-page treatment. Loading: the
        // player's getters still serve the OUTGOING track. Parked (a relaunch
        // restore): the player has nothing loaded, and without this the labels
        // sat at --:-- even after metadata delivered the duration.
        [self renderRestingTimesForTrack:_playlist.currentTrack];
        if (!_waveformView.isScrubbing) {
            _waveformView.progress = 0;
        }
        [self publishNowPlaying];
        return;
    }
    NSTimeInterval position = _player.position;
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        Formatters *formatters = [Formatters sharedInstance];
        _elapsedLabel.text = [formatters durationStringFromTimeInterval:position];
        _remainingLabel.text = [formatters durationStringFromTimeInterval:MAX(0, duration - position)];
        // The display link owns the waveform while playing; this 3 Hz write
        // is the only one while paused or parked, and they agree otherwise.
        if (!_waveformView.isScrubbing && !_seekInFlight) {
            _waveformView.progress = position / duration;
        }
    }
    else {
        _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
        _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
    }
    [self publishNowPlaying];
}

#pragma mark - Playback

- (void)playCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _errorText = nil;
    _parked = NO;
    _seekInFlight = NO;
    // Before the header render, so the bind's refresh already draws at rest.
    _trackStartPending = YES;
    [_audioSession activate];
    [self renderHeaderForTrack:track];
    [self scrollToCurrentPageAnimated:YES];
    [self requestWaveformForIndex:_playlist.currentIndex];
    [_waveformCoordinator pruneAroundIndex:_playlist.currentIndex];
    [_metadataCache loadMetadataNow:track];
    [_player play:track];
    [self updatePlayButton];
}

// Parks a restored track: everything renders, nothing plays.
- (void)parkCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _parked = YES;
    _seekInFlight = NO;
    _trackStartPending = NO;
    [self renderHeaderForTrack:track];
    [self scrollToCurrentPageAnimated:NO];
    [self requestWaveformForIndex:_playlist.currentIndex];
    [_metadataCache loadMetadataNow:track];
    [self updatePlayButton];
}

#pragma mark - Transport actions

- (void)playlistTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    [self presentTrackList];
}

- (void)playPauseTapped {
    if (_player.isPlaying) {
        [_player playPause];
    }
    else if (_player.isPaused || _player.isLoading) {
        // Loading here is a parked landing (a pause verdict mid-load, or the
        // media-reset re-park): playPause flips the landing back to playing
        // without a fresh play:, which would restart the open and lose the
        // re-park's captured position. Same verdict as audioSessionShouldResume.
        [_audioSession activate];
        [_player playPause];
    }
    else {
        // Stopped: a parked restore, a finished playlist, or a failed track.
        [self playCurrentTrack];
    }
}

- (void)nextTapped {
    if ([_playlist next]) {
        [self playCurrentTrack];
    }
}

- (void)screenTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    [self playPauseTapped];
}

// The one selection funnel for the track-list and search sheets. Clamped
// because a sheet's rows can be stale — an external "Open in Vibe" replaces
// the playlist underneath an open sheet, and Playlist.setCurrentIndex does
// not range-check, so a stale index would strand the cursor past the end.
- (void)selectTrackAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    _playlist.currentIndex = index;
    [self playCurrentTrack];
}

// Unreachable today: its only trigger is _searchBarButton, which is hidden.
// Kept, with SearchViewController, because the sheet is finished and shipping
// it is a one-line change.
- (void)searchTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    SearchViewController *search = [[SearchViewController alloc] initWithPlaylist:_playlist];
    __weak PlayerViewController *weakSelf = self;
    search.onSelectTrack = ^(NSUInteger index) {
        [weakSelf selectTrackAtIndex:index];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:search];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    _searchController = search;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentTrackList {
    TrackListViewController *list = [[TrackListViewController alloc] initWithPlaylist:_playlist];
    list.folderName = _folderSession.folderDisplayName;
    __weak PlayerViewController *weakSelf = self;
    list.onSelectTrack = ^(NSUInteger index) {
        [weakSelf selectTrackAtIndex:index];
    };
    list.onChooseFolder = ^{
        PlayerViewController *self = weakSelf;
        if (self) {
            [self->_folderSession presentPickerFromViewController:self];
        }
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                      UISheetPresentationControllerDetent.largeDetent];
    _trackListController = list;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - FolderSessionDelegate

- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<NSURL *> *)urls
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored {
    [_playlist replaceAllWithURLs:urls];
    [_waveformCoordinator reset];
    [_pagesView reloadData];
    [_metadataCache cancelAll];
    [_metadataCache loadMetadata:_playlist.tracks];

    if (selectedURL) {
        // A file pick that expanded to its directory: play the picked file,
        // not the folder's first.
        NSString *selectedPath = selectedURL.URLByStandardizingPath.path;
        NSArray<AudioTrack *> *tracks = _playlist.tracks;
        for (NSUInteger i = 0; i < tracks.count; i++) {
            if ([tracks[i].url.URLByStandardizingPath.path isEqualToString:selectedPath]) {
                _playlist.currentIndex = i;
                break;
            }
        }
    }

    if (restored) {
        NSString *fileName = session.persistedTrackFileName;
        if (!selectedURL && fileName) {
            NSArray<AudioTrack *> *tracks = _playlist.tracks;
            for (NSUInteger i = 0; i < tracks.count; i++) {
                if ([tracks[i].url.lastPathComponent isEqualToString:fileName]) {
                    _playlist.currentIndex = i;
                    break;
                }
            }
        }
        [self parkCurrentTrack];
    }
    else {
        [self playCurrentTrack];
    }
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    if (_playlist.count == 0) {
        [self showEmptyState];
        _emptyHintLabel.text = STR_ERROR_FOLDER_EMPTY;
    }
}

- (void)folderSessionRestoreDidFail:(FolderSession *)session {
    if (_playlist.count == 0) {
        [self showEmptyState];
    }
}

// One external open at a time: the session's playlist model is a directory,
// not an ad-hoc set. A multi-file share adopts the filename-sorted first —
// deterministic, unlike NSSet's anyObject — and when a folder grant covers
// its parent, the expansion pulls the siblings in anyway.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    UIOpenURLContext *context = [contexts.allObjects
            sortedArrayUsingComparator:^NSComparisonResult(UIOpenURLContext *a, UIOpenURLContext *b) {
        return [a.URL.lastPathComponent localizedStandardCompare:b.URL.lastPathComponent];
    }].firstObject;
    if (context) {
        [_folderSession openExternalURL:context.URL openInPlace:context.options.openInPlace];
    }
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // The art window's indexes name tracks that are gone.
    [_artHeldPages removeAllIndexes];
    _trackListController.folderName = _folderSession.folderDisplayName;
    [_trackListController reloadAll];
    [_searchController reloadAll];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [_pagesView reloadData];
    [_trackListController reloadAll];
    [_searchController reloadAll];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [_trackListController reloadTrackAtIndex:index];
}

// No art discard here: the departing track is usually the page right beside
// the arriving one, and releasing its decode on every commit made a swipe back
// re-read and re-decode the file. The art window owns retention now, and
// renderHeaderForTrack: moves it.
- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [_trackListController reloadTrackAtIndex:previousIndex];
    [_trackListController reloadTrackAtIndex:playlist.currentIndex];
}

#pragma mark - AudioSessionControllerDelegate

- (BOOL)audioSessionShouldPause:(AudioSessionController *)controller {
    BOOL wasPlaying = _player.isPlaying;
    if (wasPlaying) {
        // While Loading this toggles the landing to parked instead: the
        // engine never starts against the interrupted session, and
        // shouldResume's isLoading branch flips it back.
        [_player playPause];
    }
    return wasPlaying;
}

- (void)audioSessionShouldResume:(AudioSessionController *)controller {
    if (_player.isPaused || _player.isLoading) {
        [_audioSession activate];
        [_player playPause];
    }
}

- (void)audioSessionEngineConfigurationChanged:(AudioSessionController *)controller {
    [_player recoverFromEngineConfigurationChange];
}

- (void)audioSessionMediaServicesWereReset:(AudioSessionController *)controller {
    // Every live audio object died with the media server. Capture the
    // playhead (the position getter serves its last-valid cache), rebuild the
    // engine, and re-park the current track there — paused, never blasting
    // back into playback after a server crash. The park's didStartPlaying:
    // settles the header, waveform and Now Playing card.
    AudioTrack *track = _playlist.currentTrack;
    NSTimeInterval position = _player.position;
    [_player reinitializeAfterMediaServicesReset];
    _seekInFlight = NO;
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    if (track) {
        _parked = YES;
        [_player play:track atPosition:position startPaused:YES];
    }
    else {
        [self updatePlayButton];
        [self updatePlaybackUI];
    }
}

@end
