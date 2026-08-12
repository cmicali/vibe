//
//  PlayerViewController.m
//  Vibe (iOS)
//

#import "PlayerViewController.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioSessionController.h"
#import "DownloadProgressMonitor.h"
#import "FolderSession.h"
#import "Playlist.h"
#import "NowPlayingController.h"
#import "SearchViewController.h"
#import "TrackListViewController.h"
#import "TrackPageCell.h"
#import "UIUpdateTimer.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"
#if DEBUG
// The Debug category's state dump only.
#import "AppSettings.h"
#import "MusicalKey.h"
#endif

static const NSUInteger kUIUpdateHz = 3;

// CADisplayLink retains its target for the link's lifetime; aiming it through
// a weak proxy keeps the controller's dealloc reachable, so the invalidate
// there is real rather than aspirational.
@interface VibeWeakProxy : NSProxy
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation VibeWeakProxy {
    __weak id _target;
}

+ (instancetype)proxyWithTarget:(id)target {
    VibeWeakProxy *proxy = [self alloc];
    proxy->_target = target;
    return proxy;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_target methodSignatureForSelector:selector]
            ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_target]; // nil target: the invocation no-ops
}

@end

// The in-cell geometry's NOMINAL numbers, duplicated from TrackPageCell so
// the overlay chrome lines up without constraining across the cell boundary:
// the empty-state line sits at the nominal center of the cell's waveform
// box — where the two-box stack's centering puts it at standard text size.
// One pair per orientation; landscape's waveform is bottom-anchored, so its
// inset is exact rather than centering slack.
static const CGFloat kWaveformHeight = 180;
static const CGFloat kWaveformBottomInset = 118;   // nominal: bar clearance + time row + centering slack
static const CGFloat kWaveformHeightLandscape = 120;
static const CGFloat kWaveformBottomInsetLandscape = 91;  // bar clearance + time row

@interface PlayerViewController () <AudioPlayerDelegate, PlaylistObserver,
        AudioTrackMetadataCacheDelegate, AudioWaveformCacheDelegate,
        WaveformScrubberViewDelegate, NowPlayingControllerDelegate,
        AudioSessionControllerDelegate, FolderSessionDelegate,
        UIGestureRecognizerDelegate, UICollectionViewDataSource,
        UICollectionViewDelegateFlowLayout>
@end

@implementation PlayerViewController {
    AudioPlayer             *_player;
    Playlist                *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    AudioWaveformCache      *_waveformCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    UIUpdateTimer           *_updateTimer;
    // Drives the scrolling waveform at display rate while playing in the
    // foreground; the 3 Hz timer is far too coarse for a moving waveform.
    CADisplayLink           *_scrollLink;
    BOOL                    _foreground;
    // seekToPosition: fades down before rescheduling, so position briefly
    // reports the pre-seek value; holding the target until didFinishSeeking:
    // keeps the waveform from snapping back for those frames.
    float                   _pendingSeekProgress;
    BOOL                    _seekInFlight;
    // The same guard for a track change: until didStartPlaying: lands, the
    // player's getters still serve the OUTGOING track, so the new page's
    // waveform and time labels render the incoming track at rest instead of
    // the stale position (which then snapped to zero when the open landed).
    BOOL                    _trackStartPending;

    // The track pager, Photos-style: one full-screen cell per track (blurred
    // art + header), interactively draggable to the neighbors. The chrome —
    // waveform, transport, time, bottom bar — overlays it and never scrolls.
    // The screen is forced dark so text and the waveform read over any art.
    UICollectionView        *_pagesView;
    UICollectionViewFlowLayout *_pagesLayout;
    UILabel                 *_emptyHintLabel;
    UIView                  *_emptyLineView;
    NSLayoutConstraint      *_emptyLineCenterY;  // re-aimed per orientation
    // Every page cell carries its own waveform view; these are BINDINGS to
    // the current page's views, rebound when the current cell appears or is
    // recreated, so the live-update paths (and the debug channel) keep one
    // stable name for "the playing track's waveform and time labels".
    WaveformScrubberView    *_waveformView;
    UILabel                 *_elapsedLabel;
    UILabel                 *_remainingLabel;
    // The one in-flight waveform load's target page, the latest snapshot per
    // page for re-hydrating reloaded cells, and which pages have their full
    // waveform. One load exists at a time (the cache's contract): showing a
    // neighbor retargets it, and a drag-back retargets it back.
    NSUInteger              _waveformLoadIndex;
    NSMutableDictionary<NSNumber *, CodableAudioWaveform *> *_pageWaveforms;
    NSMutableIndexSet       *_completePages;
    TrackPageCell           *_boundPage;        // the current page the chrome bindings point into
    UIButton                *_playPauseButton;  // bound: the current page's glyph
    UIButton                *_searchBarButton;  // Messages-style glass search bar
    UIButton                *_folderButton;     // the compose-position circle
    UITapGestureRecognizer  *_emptyStateTap;

    TrackListViewController *_trackListController;

    // Polls a materializing cloud file's size while the loading indicator is
    // up; nil otherwise.
    DownloadProgressMonitor *_downloadMonitor;
    // An inline playback error, shown on the artist line until the next track
    // event, exactly like the mac header.
    NSString                *_errorText;
    // A restored track is parked: header, waveform, and metadata are loaded,
    // but nothing plays until the user asks.
    BOOL                    _parked;
    // A size transition (rotation, iPad window resize) is animating: the
    // pager's offset is not page-aligned at the new width, so commits hold.
    BOOL                    _windowResizeInFlight;
    // The last root size the pager was laid out for; layout passes at an
    // unchanged size skip the flow-layout invalidation.
    CGSize                  _lastLayoutSize;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Forced dark, like the Apple Music and SoundCloud player screens: every
    // label and the waveform must read over arbitrary blurred art.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];

    _waveformLoadIndex = NSNotFound;
    _pageWaveforms = [NSMutableDictionary dictionary];
    _completePages = [NSMutableIndexSet indexSet];

    _playlist = [[Playlist alloc] init];
    _playlist.observer = self;
    _metadataCache = [[AudioTrackMetadataCache alloc] init];
    _metadataCache.delegate = self;
    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCache.delegate = self;
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
    // Geometry and color mirror the scrubber's own placeholder (2pt at the
    // waveform strip's vertical center; the screen is forced dark).
    _emptyLineView = [[UIView alloc] init];
    _emptyLineView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.275];
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
    [root addSubview:_searchBarButton];

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
        [_emptyLineView.heightAnchor constraintEqualToConstant:2],

        [_searchBarButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_searchBarButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
        [_searchBarButton.heightAnchor constraintEqualToConstant:52],
        [_folderButton.leadingAnchor constraintEqualToAnchor:_searchBarButton.trailingAnchor constant:12],
        [_folderButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_folderButton.centerYAnchor constraintEqualToAnchor:_searchBarButton.centerYAnchor],
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
            ? -(kWaveformBottomInsetLandscape + kWaveformHeightLandscape / 2)
            : -(kWaveformBottomInset + kWaveformHeight / 2);
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

#pragma mark - Per-page waveforms

- (TrackPageCell *)cellAtIndex:(NSUInteger)index {
    return (TrackPageCell *)[_pagesView cellForItemAtIndexPath:
            [NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
}

// Points the live-update bindings at the current page's views.
- (void)bindChromeToCell:(TrackPageCell *)cell {
    if (!cell) {
        return;
    }
    _boundPage = cell;
    _waveformView = cell.waveformView;
    _elapsedLabel = cell.elapsedLabel;
    _remainingLabel = cell.remainingLabel;
    _playPauseButton = cell.playPauseButton;
    // A rebind means a fresh (or reloaded) cell whose labels came back at
    // their reuse defaults; while paused no timer tick will repopulate them,
    // so refresh now — the play glyph's symbol and visibility included.
    [self updatePlaybackUI];
    [self updatePlayButton];
}

// Retargets the single waveform load at a page. An index the pipeline is
// already pointed at is left ALONE — a load is in flight or has delivered,
// and restarting it on every cell reload would keep killing the decode so
// no waveform ever completes. A retargeted-back page with its full snapshot
// in hand needs no reload at all; hydration shows it.
- (void)requestWaveformForIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (!track || _waveformLoadIndex == index) {
        return;
    }
    _waveformLoadIndex = index;
    [_waveformCache cancelLoad];
    if ([_completePages containsIndex:index] && _pageWaveforms[@(index)]) {
        return;
    }
    [_completePages removeIndex:index];
    [_waveformCache loadWaveformForTrack:track];
}

// Snapshots exist to re-hydrate nearby pages instantly; distant ones reload
// from the disk cache in milliseconds, so the dictionary stays a window
// around the current page instead of growing one full waveform per track
// ever visited. The in-flight load's target is kept wherever it is.
- (void)prunePageWaveformsAroundIndex:(NSUInteger)index {
    static const NSUInteger kKeepRadius = 2;
    for (NSNumber *key in _pageWaveforms.allKeys) {
        NSUInteger page = key.unsignedIntegerValue;
        if (page != _waveformLoadIndex
                && (page > index + kKeepRadius || index > page + kKeepRadius)) {
            [_pageWaveforms removeObjectForKey:key];
            [_completePages removeIndex:page];
        }
    }
}

// Reloaded and recycled cells come back blank; the latest snapshot puts the
// waveform straight back without waiting for a fresh decode. With no
// snapshot in hand the page animates the loading line instead of sitting
// blank — on a network folder the decode behind it is routinely slow — and
// showWaveform: ends the line when data arrives.
- (void)hydrateWaveformInCell:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    CodableAudioWaveform *snapshot = _pageWaveforms[@(index)];
    if (snapshot) {
        [cell.waveformView showWaveform:snapshot];
    }
    else {
        [cell.waveformView showLoadingIndicator];
    }
}

#pragma mark - Track pager

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

// A page coming on screen: hydrate its waveform from the latest snapshot,
// and start (or re-target) the load so a neighbor pulled into view arrives
// with its own track's waveform loading. Playback does NOT switch here —
// only the settled page commits, in commitVisiblePage.
- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *page = (TrackPageCell *)cell;
    NSUInteger index = (NSUInteger)indexPath.item;

    if (page.waveformView.delegate != self) {
        page.waveformView.delegate = self;
        // The pager yields horizontal drags on the waveform surface to the
        // scrubber; page-drag starts anywhere else.
        for (UIGestureRecognizer *recognizer in page.waveformView.gestureRecognizers) {
            if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
                [_pagesView.panGestureRecognizer requireGestureRecognizerToFail:recognizer];
            }
        }
        [page.playPauseButton addTarget:self action:@selector(playPauseTapped)
                       forControlEvents:UIControlEventTouchUpInside];
    }

    [self hydrateWaveformInCell:page atIndex:index];
    if (![_completePages containsIndex:index]) {
        [self requestWaveformForIndex:index];
    }

    if (index == _playlist.currentIndex) {
        [self bindChromeToCell:page];
    }
    else {
        // A neighbor at rest: track start, and the duration once metadata
        // knows it.
        [PlayerViewController renderRestingTimesForTrack:[_playlist trackAtIndex:index]
                                                  elapsed:page.elapsedLabel
                                                remaining:page.remainingLabel];
    }
}

- (void)configurePage:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    BOOL showError = index == _playlist.currentIndex && _errorText;
    // Neighbors show their cached thumbnail — under the blur the 128px
    // thumbnail and the full decode are indistinguishable, and only the
    // current track ever decodes full art. A track with no art gets the
    // mac's vinyl placeholder.
    [cell configureWithTitle:(track.hasArtistAndTitle ? track.title : track.singleLineTitle)
                  titleColor:[UIColor labelColor]
                      artist:(showError ? _errorText
                                        : (track.hasArtistAndTitle ? track.artist : @""))
                 artistColor:(showError ? [UIColor systemRedColor]
                                        : [UIColor secondaryLabelColor])
                    fileInfo:[self fileInfoTextForTrack:track]
                         art:(track.albumArt ?: track.thumbnailAlbumArt
                                              ?: [UIImage imageNamed:@"record-bg"])];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *cell = [collectionView
            dequeueReusableCellWithReuseIdentifier:TrackPageCell.reuseIdentifier
                                      forIndexPath:indexPath];
    [self configurePage:cell atIndex:(NSUInteger)indexPath.item];
    // Reuse hands back the glyph at its resting look; stamp the live chrome
    // state so a page never appears with the wrong visibility.
    cell.playPauseButton.alpha = [self chromeAlpha];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return _pagesView.bounds.size;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self aimEmptyLine];
    // Page size follows the view, and the offset must stay page-aligned
    // through the first layout after a restore. Only on a real size change:
    // this runs on every root layout pass (sheet presentations, safe-area
    // churn), and an unconditional invalidation re-prepares the whole layout
    // each time.
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, _lastLayoutSize)) {
        return;
    }
    _lastLayoutSize = size;
    [_pagesLayout invalidateLayout];
    if (!_pagesView.isDragging && !_pagesView.isDecelerating) {
        [self scrollToCurrentPageAnimated:NO];
    }
}

// Rotation and window resize: re-page alongside the transition so the
// current page stays centered instead of the offset landing between pages at
// the new width. The in-flight flag keeps commitVisiblePage from rounding a
// mid-resize offset to a neighbor page — which would switch tracks.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    _windowResizeInFlight = YES;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self->_pagesLayout invalidateLayout];
        [self scrollToCurrentPageAnimated:NO];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        self->_windowResizeInFlight = NO;
        [self scrollToCurrentPageAnimated:NO];
    }];
}

- (void)scrollToCurrentPageAnimated:(BOOL)animated {
    CGFloat width = _pagesView.bounds.size.width;
    if (width <= 0 || _playlist.count == 0) {
        return;
    }
    CGPoint target = CGPointMake(width * (CGFloat)_playlist.currentIndex, 0);
    if (!CGPointEqualToPoint(_pagesView.contentOffset, target)) {
        [_pagesView setContentOffset:target animated:animated];
    }
}

// In place when the page has a live cell: reloadItemsAtIndexPaths: swaps the
// full-screen cell with a crossfade — the whole blurred backdrop dims on
// every track commit and metadata/art delivery — and recycles the waveform
// with it. Pages without a cell reload so a prefetched one cannot come on
// screen stale.
- (void)refreshPageAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    TrackPageCell *cell = [self cellAtIndex:index];
    if (cell) {
        [self configurePage:cell atIndex:index];
    }
    else {
        [_pagesView reloadItemsAtIndexPaths:
                @[[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]]];
    }
}

// The grab-and-pull commit, Photos semantics: whatever page the drag settles
// on becomes the current track; pulling back to the same page changes
// nothing.
- (void)commitVisiblePage {
    CGFloat width = _pagesView.bounds.size.width;
    if (width <= 0 || _playlist.count == 0 || _windowResizeInFlight) {
        return;
    }
    NSUInteger page = (NSUInteger)MAX(0.0, round(_pagesView.contentOffset.x / width));
    page = MIN(page, _playlist.count - 1);
    if (page != _playlist.currentIndex) {
        _playlist.currentIndex = page;
        [self playCurrentTrack];
    }
    else if (_waveformLoadIndex != page) {
        // Pulled a neighbor into view and let go: the preview load retargeted
        // the pipeline, so point it back at the current page (a no-op reload
        // when its waveform had already fully arrived).
        [self requestWaveformForIndex:page];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self commitVisiblePage];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self commitVisiblePage];
    }
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

// The mac codec line's composition: each part appended only when present, so
// the label never shows "(null) kbps" or "0.0 kHz".
- (NSString *)fileInfoTextForTrack:(AudioTrack *)track {
    if (!track.metadata.fileType) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:track.metadata.fileType];
    if (!track.metadata.isLossless && track.metadata.bitrate) {
        [parts addObject:[NSString stringWithFormat:STR_LABEL_BITRATE,
                [[Formatters sharedInstance] decimalString:track.metadata.bitrate.doubleValue
                                            fractionDigits:0]]];
    }
    if (track.metadata.sampleRate) {
        [parts addObject:[NSString stringWithFormat:STR_LABEL_SAMPLE_RATE,
                [[Formatters sharedInstance] decimalString:track.metadata.sampleRate.doubleValue / 1000
                                            fractionDigits:1]]];
    }
    return [parts componentsJoinedByString:VibeNotLocalized(@" | ")];
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
    return (_player.isPlaying || _playlist.count == 0) ? 0 : 1;
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

- (void)updateScrollLinkState {
    _scrollLink.paused = !(_player.isPlaying && _foreground);
}

- (void)scrollTick:(CADisplayLink *)link {
    if (_waveformView.isScrubbing) {
        return;
    }
    if (_trackStartPending) {
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
    if (_trackStartPending || (_parked && _player.duration <= 0)) {
        // The current track at rest — the neighbor-page treatment. Pending: the
        // player's getters still serve the OUTGOING track. Parked-unopened (a
        // relaunch restore): the player has nothing loaded, and without this
        // the labels sat at --:-- even after metadata delivered the duration.
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

- (void)publishNowPlaying {
    NowPlayingPlaybackState state = NowPlayingPlaybackStateStopped;
    if (_player.isPlaying) {
        state = NowPlayingPlaybackStatePlaying;  // Loading included: play is imminent
    }
    else if (_player.isPaused) {
        state = NowPlayingPlaybackStatePaused;
    }
    AudioTrack *track = (_parked || _trackStartPending || _player.currentTrack)
            ? _playlist.currentTrack : nil;
    if (track) {
        [self dispatchAlbumArtLoadForTrack:track];
    }
    // The player's duration is 0 while pending or parked-unopened; the
    // track's metadata duration keeps the card's timeline real there.
    NSTimeInterval playerDuration = _player.duration;
    [_nowPlaying updateWithTrack:track
                        position:(_trackStartPending ? 0 : _player.position)
                        duration:(playerDuration > 0 ? playerDuration : track.duration)
                           state:state
                            rate:1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
}

// Cache-hit metadata does not carry the art bytes, and extracting them
// re-reads the audio file, which can block on an undownloaded cloud file, so
// the decode runs off the main thread — the mac's ArtworkDisplayController
// dispatch. Until it lands, albumArt reads nil and the Now Playing card and
// the current page show no full-res art; the resolve republishes both.
- (void)dispatchAlbumArtLoadForTrack:(AudioTrack *)track {
    AudioTrackMetadata *metadata = track.metadata;
    if (!metadata.albumArtNeedsLoad || metadata.albumArtLoadDispatched) {
        return;
    }
    metadata.albumArtLoadDispatched = YES;
    __weak PlayerViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VibeImage *loaded = metadata.albumArt;  // may block; background thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Resolved either way; albumArtNeedsLoad is NO after any
            // completion, so no duplicate dispatch can follow.
            metadata.albumArtLoadDispatched = NO;
            PlayerViewController *self = weakSelf;
            if (!self) {
                return;
            }
            if (![self->_playlist isCurrentTrack:track]) {
                // Skipped away before the load resolved; nothing else would
                // demote the full-resolution decode this load just pinned.
                [metadata discardDecodedAlbumArt];
                return;
            }
            if (loaded) {
                [self refreshPageAtIndex:self->_playlist.currentIndex];
                [self publishNowPlaying];
            }
        });
    });
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
    [self prunePageWaveformsAroundIndex:_playlist.currentIndex];
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
    else if (_player.isPaused) {
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
    _waveformLoadIndex = NSNotFound;
    [_pageWaveforms removeAllObjects];
    [_completePages removeAllIndexes];
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

- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    UIOpenURLContext *context = contexts.anyObject;
    if (context) {
        [_folderSession openExternalURL:context.URL openInPlace:context.options.openInPlace];
    }
}

#pragma mark - AudioPlayerDelegate

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [_waveformView showLoadingIndicator];
    // Best-effort determinate fill while the provider materializes the file;
    // the URL is re-matched at delivery because the monitor outlives fast
    // track changes.
    [_downloadMonitor cancel];
    DownloadProgressMonitor *monitor = [[DownloadProgressMonitor alloc] initWithURL:track.url];
    _downloadMonitor = monitor;
    NSURL *url = track.url;
    __weak PlayerViewController *weakSelf = self;
    [monitor startWithHandler:^(float fraction) {
        PlayerViewController *self = weakSelf;
        if (self && [self->_playlist.currentTrack.url isEqual:url]) {
            [self->_waveformView setLoadingProgress:fraction];
        }
    }];
    [self publishNowPlaying];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    _errorText = nil;
    _trackStartPending = NO;
    // The open landed, so the file is materialized; the monitor's work is
    // done whatever it last reported.
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    [self renderHeaderForTrack:track];
    // Not a blanket hideLoadingIndicator: the open landing says nothing about
    // the waveform decode, which may still be streaming over the network.
    // Re-hydration repaints a snapshot already in hand (ending the slow-open
    // shimmer that replaced it); otherwise the line keeps animating until
    // showWaveform: delivers.
    [self hydrateWaveformInCell:[self cellAtIndex:_playlist.currentIndex]
                        atIndex:_playlist.currentIndex];
    // The dataless-placeholder retry: a cache miss skipped while the player's
    // own open was materializing the file parses now.
    [_metadataCache loadMetadataNow:track];
    NSUInteger nextIndex = _playlist.currentIndex + 1;
    [_player prefetchTrack:_playlist.hasNextTrack ? [_playlist trackAtIndex:nextIndex] : nil];
    _folderSession.persistedTrackFileName = track.url.lastPathComponent;
    // The landing can be parked — a pause verdict during the load, or the
    // media-reset re-park — in which case playback is idle, so the session is
    // released just as a pause releases it.
    BOOL playing = _player.isPlaying;
    _updateTimer.wanted = playing;
    [self updateScrollLinkState];
    if (!playing) {
        [_audioSession deactivateWhenIdle];
    }
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    // A resume from a media-reset (or interrupted-load) park goes through
    // playPause directly, never playCurrentTrack, so the flag clears here.
    _parked = NO;
    _updateTimer.wanted = YES;
    [self updateScrollLinkState];
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    _seekInFlight = NO;
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    if ([_playlist next]) {
        [self playCurrentTrack];
        return;
    }
    // End of playlist: park on the last track, ready to replay.
    _parked = YES;
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    _waveformView.progress = 0;
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack {
    // The player spliced into the pre-scheduled next track; audio never
    // stopped. This handler's job is the bookkeeping half of an auto-advance:
    // move the playlist cursor and run the per-track refresh, without play:.
    // A boundary that raced a track change belongs to the operation that
    // superseded it.
    if (![_playlist isCurrentTrack:finishedTrack]) {
        return;
    }
    // The playlist owns what "next" means. If its next row is no longer the
    // track the player spliced into — a replace raced the boundary —
    // correctness beats gaplessness: treat it as an ordinary track end, whose
    // play replaces the spliced audio with the real successor.
    if (startedTrack != [_playlist trackAtIndex:_playlist.currentIndex + 1]) {
        [self audioPlayer:audioPlayer didFinishPlaying:finishedTrack];
        return;
    }
    [_playlist next];
    [self scrollToCurrentPageAnimated:YES];
    [self requestWaveformForIndex:_playlist.currentIndex];
    [self prunePageWaveformsAroundIndex:_playlist.currentIndex];
    // The rest of the per-track refresh — header, metadata, prefetch of the
    // new next (which re-arms the splice), Now Playing — is exactly
    // didStartPlaying:'s body, and its identity guard now passes.
    [self audioPlayer:audioPlayer didStartPlaying:startedTrack];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID {
    // macOS-only path; never sent on iOS.
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    NSURL *url = error.userInfo[kVibeAudioErrorTrackURLKey];
    AudioTrack *current = _playlist.currentTrack;
    if (url && current && ![url isEqual:current.url]) {
        return;  // a stale delivery racing a track change
    }
    _errorText = [self statusForPlayError:error];
    _seekInFlight = NO;
    _trackStartPending = NO;
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    [_waveformView hideLoadingIndicator];
    if (current) {
        [self renderHeaderForTrack:current];
    }
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    [self updatePlayButton];
    [self publishNowPlaying];
}

// The iOS twin of MainPlayerController's statusForPlayError: same codes,
// same strings.
- (NSString *)statusForPlayError:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:   return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:     return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:  return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:  return STR_ERROR_DEVICE_UNAVAILABLE;
            default: break;
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    [_trackListController reloadAll];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [_pagesView reloadData];
    [_trackListController reloadAll];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [_trackListController reloadTrackAtIndex:index];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    if (previousIndex != playlist.currentIndex) {
        // Only the current track holds decoded full-res art; the thumbnail
        // stays and the on-demand load re-arms if the track comes back.
        [[playlist trackAtIndex:previousIndex].metadata discardDecodedAlbumArt];
    }
    [_trackListController reloadTrackAtIndex:previousIndex];
    [_trackListController reloadTrackAtIndex:playlist.currentIndex];
}

#pragma mark - AudioTrackMetadataCacheDelegate

- (void)didLoadMetadata:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row >= 0) {
        [_trackListController reloadTrackAtIndex:(NSUInteger)row];
        [self refreshPageAtIndex:(NSUInteger)row];
    }
    if ([_playlist isCurrentTrack:track]) {
        // The full refresh, not just the publish: a parked track's time
        // labels render from this delivery's duration.
        [self updatePlaybackUI];
    }
}

#pragma mark - AudioWaveformCacheDelegate

- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    // No URL rides on this delivery; the pipeline has one load at a time and
    // _waveformLoadIndex names its target page (cancelLoad before every
    // retarget is the race guard, per the cache's contract). The snapshot is
    // kept for re-hydrating that page if its cell reloads or recycles.
    if (_waveformLoadIndex == NSNotFound) {
        return;
    }
    _pageWaveforms[@(_waveformLoadIndex)] = waveform;
    if (percentLoaded >= 1.0f) {
        [_completePages addIndex:_waveformLoadIndex];
    }
    [[self cellAtIndex:_waveformLoadIndex].waveformView showWaveform:waveform];
}

// The mac's late-delivery and duplicate-row contract: the value is valid for
// every row owning this URL, so stamp them all. Matching only the CURRENT
// track dropped a neighbor preview's delivery, and the commit's skip-reload
// path never re-fires it — that track then had no BPM/key for the session.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    [[_playlist indexesOfTracksWithURL:url]
            enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [self->_playlist trackAtIndex:index].detectedBPM = bpm;
    }];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url {
    [[_playlist indexesOfTracksWithURL:url]
            enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [self->_playlist trackAtIndex:index].detectedKey = (VibeMusicalKey)key;
    }];
}

#pragma mark - WaveformScrubberViewDelegate

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage {
    if (view != _waveformView) {
        return;  // a neighbor page's preview waveform does not drive the player
    }
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        _pendingSeekProgress = percentage;
        _seekInFlight = YES;
        [_player seekToPosition:duration * percentage];
    }
    else if (_parked) {
        [self playCurrentTrack];
    }
}

#pragma mark - NowPlayingControllerDelegate

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (!_player.isPlaying) {
        [self playPauseTapped];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    if (_player.isPlaying) {
        [_player playPause];
    }
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPauseTapped];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self nextTapped];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
    else {
        [_player seekToPosition:0];
    }
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    [_player seekToPosition:position];
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

#if DEBUG

#pragma mark - Debug command surface

// In the class's own file so the category reads the ivars directly; the verbs
// live in DebugCommands.m.

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugStateDictionary {
    AudioTrack *track = _playlist.currentTrack;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (AudioTrack *t in _playlist.tracks) {
        if (files.count == 100) {
            [files addObject:[NSString stringWithFormat:@"… %lu more",
                    (unsigned long)(_playlist.count - 100)]];
            break;
        }
        [files addObject:t.url.lastPathComponent ?: @""];
    }
    return @{
        @"player": @{
            @"state": _player.isPlaying ? @"playing" : (_player.isPaused ? @"paused" : @"stopped"),
            @"position": @(_player.position),
            @"duration": @(_player.duration),
            @"numChannels": @(_player.numChannels),
            @"gaplessArmed": @(_player.isGaplessArmed),
            @"silent": @([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]),
            @"noAudioHw": @([NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"]),
        },
        @"currentTrack": track ? @{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            @"bpm": @(track.bpm),
            // The resolved key (tag over analysis); empty strings when unknown.
            @"key": VibeMusicalKeyMusicalName(track.key),
            @"camelot": VibeMusicalKeyCamelotName(track.key),
        } : (id)NSNull.null,
        @"playlist": @{
            @"count": @(_playlist.count),
            @"currentIndex": @(_playlist.currentIndex),
            @"files": files,
        },
        @"ui": @{
            @"elapsed": _elapsedLabel.text ?: @"",
            @"remaining": _remainingLabel.text ?: @"",
            @"emptyHintShown": @(!_emptyHintLabel.isHidden),
            @"transportShown": @(_playPauseButton.alpha > 0),
            @"waveformProgress": @(_waveformView.progress),
            @"waveformBaked": @(_waveformView.isShowingBakedWaveform),
            @"isScrubbing": @(_waveformView.isScrubbing),
            @"parked": @(_parked),
            @"trackStartPending": @(_trackStartPending),
            @"foreground": @(_foreground),
            @"error": _errorText ?: @"",
        },
        @"settings": @{
            @"waveformStyle": Settings.waveformStyle ?: @"",
            @"analyzeBPM": @(Settings.analyzeBPM),
            @"analyzeKey": @(Settings.analyzeKey),
        },
    };
}

- (NSDictionary *)debugActionSummary {
    return @{
        @"ok": @YES,
        @"state": _player.isPlaying ? @"playing" : (_player.isPaused ? @"paused" : @"stopped"),
        @"index": @(_playlist.currentIndex),
        @"count": @(_playlist.count),
        @"position": @(_player.position),
        @"parked": @(_parked),
    };
}

- (void)debugPlayPause {
    [self playPauseTapped];
}

- (void)debugNext {
    [self nextTapped];
}

- (void)debugPrevious {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        float p = (float)MAX(0.0, MIN(1.0, seconds / duration));
        [self waveformScrubberView:_waveformView didSeek:p];
    }
}

- (void)debugOpenPath:(NSString *)path {
    [_folderSession openExternalURL:[NSURL fileURLWithPath:path] openInPlace:YES];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return _metadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

@end

#endif
