//
//  PlayerViewController.m
//  Vibe (iOS)
//
//  The chrome, the update funnel and the PlaybackController events. The
//  categories share PlayerViewControllerInternal.h.
//

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlayerViewController+Pager.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "AudioWaveformCache.h"
#import "FXPadView.h"
#import "PageWaveformCoordinator.h"
#import "TrackPageCell.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "VibeWeakProxy.h"
#import "WaveformRendererRegistry.h"
#import "WaveformScrubberView.h"

// Bounded because AVKit's end edge is not guaranteed.
static const NSTimeInterval kRoutePickerHoldSeconds = 10;

// TRAP: requiring the scrubber's pan to fail is not enough. At a content edge,
// UIKit's nested-scroll arbitration never begins the scrubber's pan, so the
// requirement is met and the pager takes the drag, turning the page. Declining
// by hit-test keeps it with the scrubber; an override, since a scroll view owns
// its pan's delegate.
@interface TrackPagerView : UICollectionView
@end

@implementation TrackPagerView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == self.panGestureRecognizer) {
        UIView *hit = [self hitTest:[recognizer locationInView:self] withEvent:nil];
        for (UIView *view = hit; view && view != self; view = view.superview) {
            if ([view isKindOfClass:[WaveformScrubberView class]]) {
                // An unloaded scrubber hands the gesture to the pager, or the
                // empty strip is a swipe dead zone.
                if (((WaveformScrubberView *)view).isScrubbingEnabled) {
                    return NO;
                }
                break;
            }
        }
    }
    return [super gestureRecognizerShouldBegin:recognizer];
}
@end

// Set once the cache written before tempo detection has been cleared.
static NSString *const kWaveformTempoBackfillKey = @"VibeiOSWaveformTempoBackfilled";

@implementation PlayerViewController {
    // The model's 3 Hz tick is too coarse for a moving waveform.
    CADisplayLink           *_scrollLink;
    // The waveform provider's bands answer as of the last settings change, so
    // only the change into a style reading them asks for the pages again.
    BOOL                     _waveformBandsWanted;

    UIView                  *_grabberView;
    UIButton                *_grabberTarget;
    UIPanGestureRecognizer  *_minimizePan;
}

#pragma mark - Lifecycle

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Forced dark: every label must read over arbitrary blurred art.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Before buildUI, so the first cell to display already has it.
    [self restoreWaveformZoom];
    [self buildUI];

    _waveformCache = [[AudioWaveformCache alloc] init];
    // Once: an entry cached before tempo detection existed here carries no
    // BPM, and a cache hit never re-analyzes, so those tracks would show no
    // tempo and echo at the default for as long as the entry lived. Ahead of
    // the first load on the cache's serial queue, so no lookup sees the old
    // entries.
    if (![NSUserDefaults.standardUserDefaults boolForKey:kWaveformTempoBackfillKey]) {
        [_waveformCache invalidateWithCompletion:nil];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWaveformTempoBackfillKey];
    }
    // Asked once per request, so Settings > Playback lands on the next load
    // with nothing to republish. No key: key detection is macOS-only. The
    // bands for the card's style or the widget's, which bakes from the
    // card's waveform; a nil widget style is the card's.
    _waveformCache.analysisProvider = ^VibeWaveformAnalysis{
        AppSettings *settings = AppSettings.sharedInstance;
        return (VibeWaveformAnalysis){
            .bpm = settings.analyzeBPM,
            .bands = [WaveformRendererRegistry readsBandsForIdentifier:settings.waveformStyle]
                  || [WaveformRendererRegistry readsBandsForIdentifier:settings.widgetWaveformStyle],
        };
    };
    _waveformBandsWanted = _waveformCache.analysisProvider().bands;
    _waveformCoordinator = [[PageWaveformCoordinator alloc] initWithCache:_waveformCache delegate:self];
    _artHeldPages = [NSMutableIndexSet indexSet];
    _preparedWaveforms = [NSMutableDictionary dictionary];
    _pagerHoldViews = [NSHashTable weakObjectsHashTable];

    _scrollLink = [CADisplayLink displayLinkWithTarget:[VibeWeakProxy proxyWithTarget:self]
                                              selector:@selector(scrollTick:)];
    // ~1pt/frame of motion gains nothing at 120 Hz.
    _scrollLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    _scrollLink.paused = YES;
    [_scrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    [_playback addObserver:self];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(displaySettingsDidChange)
                   name:VibeDisplaySettingsDidChangeNotification object:nil];
}

// All settings at once, visible pages only: a pooled cell is configured from
// scratch on its way back.
- (void)displaySettingsDidChange {
    // The pages in hand were likely decoded without the bands: forgotten,
    // each is asked for again as it comes up.
    BOOL bandsWanted = _waveformCache.analysisProvider().bands;
    if (bandsWanted && !_waveformBandsWanted) {
        [_waveformCoordinator reset];
        [self clearPreparedWaveforms];
        [self requestCurrentWaveform];
        [self fetchNeighborWaveforms];
    }
    _waveformBandsWanted = bandsWanted;
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        NSIndexPath *path = [_pagesView indexPathForCell:cell];
        if (path) {
            [self configurePage:cell atIndex:(NSUInteger)path.item];
        }
        [cell.waveformView syncWaveformStyle];
        [cell.waveformView syncWaveformTheme];
    }
    [self repaintTimesOnVisiblePages];
    [self refreshWaveformWindow];
}

// Reachable because the display link holds a weak proxy.
- (void)dealloc {
    [_scrollLink invalidate];
}

#pragma mark - The right time label's mode

NSString *VibeRightTimeText(NSTimeInterval position, NSTimeInterval duration) {
    Formatters *formatters = [Formatters sharedInstance];
    if (!AppSettings.sharedInstance.showRemainingTime) {
        return [formatters durationStringFromTimeInterval:duration];
    }
    // Arithmetic notation, not prose, so not localized.
    return [VibeNotLocalized(@"-") stringByAppendingString:
            [formatters durationStringFromTimeInterval:MAX(0, duration - position)]];
}

#pragma mark - UI construction

- (void)buildUI {
    UIView *root = self.view;

    _pagesLayout = [[UICollectionViewFlowLayout alloc] init];
    _pagesLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    _pagesLayout.minimumLineSpacing = 0;
    _pagesLayout.minimumInteritemSpacing = 0;
    if (root.bounds.size.width > 0 && root.bounds.size.height > 0) {
        _pagesLayout.itemSize = root.bounds.size;
    }
    _pagesView = [[TrackPagerView alloc] initWithFrame:CGRectZero
                                    collectionViewLayout:_pagesLayout];
    _pagesView.pagingEnabled = YES;
    _pagesView.showsHorizontalScrollIndicator = NO;
    _pagesView.allowsSelection = NO;
    // Two fingers are a waveform zoom, never a page swipe.
    _pagesView.panGestureRecognizer.maximumNumberOfTouches = 1;
    // alwaysBounce keeps the edge pull alive on a one-track playlist.
    _pagesView.bounces = YES;
    _pagesView.alwaysBounceHorizontal = YES;
    _pagesView.backgroundColor = [UIColor clearColor];
    // What an edge pull and the empty state reveal.
    UIImageView *backdrop = [[UIImageView alloc]
            initWithImage:[UIImage imageNamed:@"record-bg"]];
    backdrop.contentMode = UIViewContentModeScaleAspectFill;
    backdrop.clipsToBounds = YES;
    _pagesView.backgroundView = backdrop;
    // Pages must be exactly screen-sized for the paging math.
    _pagesView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _pagesView.dataSource = self;
    _pagesView.delegate = self;
    [_pagesView registerClass:TrackPageCell.class
        forCellWithReuseIdentifier:TrackPageCell.reuseIdentifier];
    _pagesView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_pagesView];

    _grabberView = [[UIView alloc] init];
    _grabberView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.35];
    _grabberView.layer.cornerRadius = 2.5;
    _grabberView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_grabberView];

    // The bar itself is five points tall.
    UIButton *grabberTarget = [UIButton buttonWithType:UIButtonTypeCustom];
    grabberTarget.backgroundColor = UIColor.clearColor;
    grabberTarget.accessibilityLabel = STR_A11Y_PLAYER_MINIMIZE;
    [grabberTarget addTarget:self action:@selector(minimizeTapped)
            forControlEvents:UIControlEventTouchUpInside];
    grabberTarget.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:grabberTarget];
    _grabberTarget = grabberTarget;

    // A paging scroll view's pan begins on movement in ANY direction, so the
    // pager waits for this one, which fails itself on the first horizontal
    // move (gestureRecognizerShouldBegin:).
    _minimizePan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                           action:@selector(minimizePanned:)];
    _minimizePan.delegate = self;
    [root addGestureRecognizer:_minimizePan];
    [_pagesView.panGestureRecognizer requireGestureRecognizerToFail:_minimizePan];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_pagesView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_pagesView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_pagesView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_pagesView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

        [_grabberView.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_grabberView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_grabberView.widthAnchor constraintEqualToConstant:46],
        [_grabberView.heightAnchor constraintEqualToConstant:5],

        [_grabberTarget.centerXAnchor constraintEqualToAnchor:_grabberView.centerXAnchor],
        [_grabberTarget.centerYAnchor constraintEqualToAnchor:_grabberView.centerYAnchor],
        [_grabberTarget.widthAnchor constraintEqualToConstant:120],
        [_grabberTarget.heightAnchor constraintEqualToConstant:44],
    ]];
}

+ (void)renderRestingTimesForTrack:(AudioTrack *)track
                           elapsed:(UILabel *)elapsed
                         remaining:(TrackPageTimeControl *)remaining {
    BOOL known = track.duration > 0;
    elapsed.text = known
            ? [[Formatters sharedInstance] durationStringFromTimeInterval:0]
            : STR_LABEL_TIME_UNKNOWN;
    // Through the one rule, or a resting page would show a bare total beside
    // a playing one's minus-prefixed remaining.
    remaining.text = known ? VibeRightTimeText(0, track.duration) : STR_LABEL_TIME_UNKNOWN;
}

- (void)renderRestingTimesForTrack:(AudioTrack *)track {
    [PlayerViewController renderRestingTimesForTrack:track
                                              elapsed:_elapsedLabel
                                            remaining:_remainingTimeControl];
}

#pragma mark - Gestures

// Downward and more vertical than horizontal; failing hands the pager the
// touch. TRAP: the test is on TRANSLATION, not velocity, which reads zero
// whenever the finger pauses — including when a slow drag crosses the slop,
// exactly when this is asked.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != _minimizePan) {
        return YES;
    }
    CGPoint translation = [_minimizePan translationInView:self.view];
    return translation.y > 0 && fabs(translation.y) > fabs(translation.x);
}

- (void)minimizePanned:(UIPanGestureRecognizer *)recognizer {
    CGFloat translation = MAX(0, [recognizer translationInView:self.view].y);
    [self.delegate playerViewController:self
                  didPanWithTranslation:translation
                               velocity:[recognizer velocityInView:self.view].y
                                  state:recognizer.state];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // The minimize pan's. By class, not frame: every page carries its own
    // waveform. What hit-tests in the route view is AVKit's, so it is
    // declined by our own class.
    for (UIView *view = touch.view; view && view != self.view; view = view.superview) {
        if (view == _grabberTarget) {
            return gestureRecognizer == _minimizePan;
        }
        if ([view isKindOfClass:[UIControl class]]
                || [view isKindOfClass:[OutputRouteView class]]
                || [view isKindOfClass:[FXPadView class]]
                || [view isKindOfClass:[WaveformScrubberView class]]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - FXPadViewDelegate

// Every position goes to the model's one funnel, and the pager is held for
// the length of the hold exactly as it is for a scrub: the pad owns the
// touch, but UIKit would still chain an overscroll into the pager. The hold
// moves only on the edges; the frames between are positions alone.
- (void)fxPadView:(FXPadView *)view didChangePosition:(CGPoint)position engaged:(BOOL)engaged {
    [_playback setFXPadPosition:position engaged:engaged];
    if (engaged != [_pagerHoldViews containsObject:view]) {
        [self setPagerHeld:engaged byView:view];
    }
}

#pragma mark - OutputRouteViewDelegate

- (void)outputRouteView:(OutputRouteView *)view isPresentingRoutes:(BOOL)presenting {
    if (presenting == _routePickerPresenting) {
        return;
    }
    _routePickerPresenting = presenting;
    uint64_t generation = ++_routePickerHoldGeneration;
    [self updateScrollLinkState];
    if (presenting) {
        // AVKit's release may never come (see the flag). Overshooting a
        // sheet still up only animates a hidden waveform.
        __weak PlayerViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kRoutePickerHoldSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PlayerViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_routePickerHoldGeneration) {
                return;
            }
            strongSelf->_routePickerPresenting = NO;
            [strongSelf updateScrollLinkState];
        });
        return;
    }
    // A destination picked against an inactive session posts no route
    // notification.
    [self updateOutputRoute];
}

#pragma mark - Presentation

- (void)setPresented:(BOOL)presented {
    if (_presented == presented) {
        return;
    }
    _presented = presented;
    [self updateScrollLinkState];
    if (presented) {
        // Minimized, the card took no ticks.
        [self updateOutputRoute];
        [self updatePlaybackUI];
        [self renderHeaderForTrack:_playlist.currentTrack];
        [self scrollToCurrentPageAnimated:NO];
    }
    else {
        [self clearPreparedWaveforms];
    }
}

- (void)setSceneActive:(BOOL)sceneActive {
    if (_sceneActive == sceneActive) {
        return;
    }
    _sceneActive = sceneActive;
    if (sceneActive) {
        // Settles a picker AVKit tore down silently, ahead of the deadline.
        _routePickerPresenting = NO;
        _routePickerHoldGeneration++;
    }
    [self updateScrollLinkState];
    if (sceneActive) {
        [self updateOutputRoute];
        [self updatePlaybackUI];
    }
}

- (BOOL)isSceneActive {
    return _sceneActive;
}

#pragma mark - Header rendering

- (void)renderHeaderForTrack:(AudioTrack *)track {
    // Here, not the currentIndex observer, so a park on the index already
    // current still moves the window.
    [self refreshArtWindow];
    [self refreshPageAtIndex:_playlist.currentIndex];
    TrackPageCell *cell = [self cellAtIndex:_playlist.currentIndex];
    if (cell) {
        [self bindChromeToCell:cell];
    }
    else {
        // A far jump: no live cell yet. Drop the bindings, or the incoming
        // track's state writes into the outgoing cell mid-scroll;
        // willDisplayCell rebinds.
        _boundPage = nil;
        _waveformView = nil;
        _elapsedLabel = nil;
        _remainingTimeControl = nil;
        _transportView = nil;
        _routeView = nil;
        _fxPadView = nil;
        _actionBar = nil;
    }
}

- (void)updatePlayButton {
    [_boundPage setGlyphPlaying:_playback.isPlaying];
    [self updateChrome];
}

- (CGFloat)chromeAlpha {
    return _playback.screenState == VibePlayerScreenStateEmpty ? 0 : 1;
}

- (void)updateChrome {
    CGFloat rowAlpha = [self chromeAlpha];
    if (_transportView.alpha == rowAlpha && _routeView.alpha == rowAlpha
            && _actionBar.alpha == rowAlpha && _fxPadView.alpha == rowAlpha) {
        return;
    }
    [UIView animateWithDuration:0.3 animations:^{
        self->_transportView.alpha = rowAlpha;
        self->_routeView.alpha = rowAlpha;
        self->_actionBar.alpha = rowAlpha;
        self->_fxPadView.alpha = rowAlpha;
    }];
}

// Every visible page, or a neighbor keeps the old route until recycled.
- (void)updateOutputRoute {
    VibeOutputRouteKind kind = _playback.outputRouteKind;
    NSString *name = _playback.outputRouteName;
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        [cell setOutputRouteKind:kind deviceName:name];
    }
}

// Paused unless the playhead moves where someone can see it. A swipe or a
// size transition counts as unseen and takes the frame-budget hold (+Pager):
// the swipe needs those frames, and during a resize the bake is down, so each
// write re-composites the live tree.
- (void)updateScrollLinkState {
    _scrollLink.paused = !(_playback.isPlaying && _sceneActive && self.isPresented
                           && !_pagerScrolling && !_pagerProgrammaticScrolling
                           && !_windowResizeInFlight && !_routePickerPresenting);
}

- (void)scrollTick:(CADisplayLink *)link {
    if (self.presentedViewController) {
        // A sheet covers the waveform; the 3 Hz tick keeps progress current.
        return;
    }
    if (_waveformView.isScrubbing) {
        return;
    }
    // The seek target FIRST: a parked scrub is Loading and in flight at once,
    // and zeroing there is the snap-back it prevents. A track change clears
    // seekInFlight.
    if (_playback.seekInFlight) {
        _waveformView.progress = _playback.pendingSeekProgress;
        return;
    }
    if (_playback.screenState == VibePlayerScreenStateLoading) {
        _waveformView.progress = 0;
        return;
    }
    NSTimeInterval duration = _playback.duration;
    if (duration > 0) {
        _waveformView.progress = _playback.position / duration;
    }
}

- (void)updatePlaybackUI {
    if (_waveformView.isScrubbing) {
        // The scrub owns the readout (didScrubToProgress:).
        return;
    }
    if (VibePlayerScreenRendersRestingTimes(_playback.screenState)) {
        // scrollTick:'s precedence.
        if (_playback.seekInFlight && !_waveformView.isScrubbing) {
            _waveformView.progress = _playback.pendingSeekProgress;
            [self renderRestingTimesForTrack:_playlist.currentTrack];
            return;
        }
        [self renderRestingTimesForTrack:_playlist.currentTrack];
        if (!_waveformView.isScrubbing) {
            _waveformView.progress = 0;
        }
        return;
    }
    NSTimeInterval position = _playback.position;
    NSTimeInterval duration = _playback.duration;
    if (duration > 0) {
        // Both change once a second; the control skips an unchanged text itself.
        NSString *elapsed = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
        if (![_elapsedLabel.text isEqualToString:elapsed]) {
            _elapsedLabel.text = elapsed;
        }
        _remainingTimeControl.text = VibeRightTimeText(position, duration);
        // The only waveform write while paused.
        if (!_waveformView.isScrubbing && !_playback.seekInFlight) {
            _waveformView.progress = position / duration;
        }
    }
    else {
        _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
        _remainingTimeControl.text = STR_LABEL_TIME_UNKNOWN;
    }
}

#pragma mark - Transport actions

- (void)playPauseTapped {
    [_playback playPause];
}

- (void)previousTapped {
    [_playback previous];
}

- (void)nextTapped {
    [_playback next];
}

- (void)shuffleTapped {
    [_playback toggleShuffle];
}

- (void)repeatTapped {
    [_playback cycleRepeatMode];
}

- (void)remainingTimeTapped {
    AppSettings.sharedInstance.showRemainingTime = !AppSettings.sharedInstance.showRemainingTime;
    [self repaintTimesOnVisiblePages];
}

// Neighbors are drawn at rest and would keep the old mode until recycled.
- (void)repaintTimesOnVisiblePages {
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        if (cell == _boundPage) {
            continue;   // updatePlaybackUI has it
        }
        NSInteger index = [_pagesView indexPathForCell:cell].item;
        if (index >= 0 && (NSUInteger)index < (NSInteger)_playlist.count) {
            [PlayerViewController renderRestingTimesForTrack:[_playlist trackAtIndex:(NSUInteger)index]
                                                     elapsed:cell.elapsedLabel
                                                   remaining:cell.remainingTimeControl];
        }
    }
    [self updatePlaybackUI];
}

- (void)minimizeTapped {
    [self.delegate playerViewControllerDidRequestMinimize:self];
}

#pragma mark - PlaybackObserver: the playlist

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [_artHeldPages removeAllIndexes];
    [_waveformCoordinator reset];
    [self clearPreparedWaveforms];
    [_pagesView reloadData];
    [self scrollToCurrentPageAnimated:NO];
}

// Inserted, not reloaded: a reload re-dequeues the visible pages, which blanks
// their waveforms and regrows them. Only when the view's count is the one
// before the append; one not yet counted already reads the new count. The
// visible pages keep their configure, so their Next is re-read here: the last
// page's was dimmed.
- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    if ((NSUInteger)[_pagesView numberOfItemsInSection:0] + indexes.count != _playlist.count) {
        [_pagesView reloadData];
        return;
    }
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray arrayWithCapacity:indexes.count];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [paths addObject:[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
    }];
    [_pagesView insertItemsAtIndexPaths:paths];
    [self applyPlayOrderToVisiblePages];
}

// No cursor-move handler, and no art discarded on a move: the departing page
// is usually the arriving one's neighbor. The art window owns retention.

#pragma mark - PlaybackObserver: the current track

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    [self scrollToCurrentPageAnimated:animated];
    // In this order: the current page's disk read goes ahead of the
    // neighbors' on the cache's serial queue.
    [self requestCurrentWaveform];
    [_waveformCoordinator pruneAroundIndex:playback.currentIndex];
    [self fetchNeighborWaveforms];
}

- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback {
    [self renderHeaderForTrack:playback.currentTrack];
}

// A track change ends every held interaction, including one on an outgoing
// page. Each view releases its own pager hold without committing a seek.
- (void)playback:(PlaybackController *)playback didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex {
    [self applyPlaybackLoadingToVisiblePages];
    // Every holder is an FXPadView or a WaveformScrubberView.
    [_pagerHoldViews.allObjects makeObjectsPerformSelector:@selector(cancelInteraction)];
    // Only the current page reads Next from the play order.
    [self applyPlayOrderToVisiblePages];
}

- (void)playbackDidChangePlayOrder:(PlaybackController *)playback {
    [self applyPlayOrderToVisiblePages];
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self updateScrollLinkState];
    [self updatePlayButton];
}

- (void)playbackDidChangeOutputRoute:(PlaybackController *)playback {
    [self updateOutputRoute];
}

- (void)playbackDidTick:(PlaybackController *)playback {
    [self updatePlaybackUI];
}

#pragma mark - PlaybackObserver: the current track's open

- (void)playbackDidBeginLoading:(PlaybackController *)playback {
    [self hydrateWaveformInCell:[self cellAtIndex:playback.currentIndex] atIndex:playback.currentIndex];
    [self applyPlaybackLoadingToVisiblePages];
}

- (void)playback:(PlaybackController *)playback didUpdateLoadingProgress:(float)fraction {
    [_waveformView setLoadingProgress:fraction];
}

// Not hideLoadingIndicator: the waveform decode may still be streaming. The
// open state and download fill end here; a cached waveform can arrive
// mid-download and must leave them alone.
//
// The waveform request for a track that was not on disk when the cursor
// moved: the cursor's request skipped it (requestCurrentWaveform). A page
// still loading or complete ignores this one.
- (void)playbackDidFinishLoading:(PlaybackController *)playback {
    [self applyPlaybackLoadingToVisiblePages];
    [self hydrateWaveformInCell:[self cellAtIndex:playback.currentIndex] atIndex:playback.currentIndex];
    [self requestCurrentWaveform];
}

- (void)playbackDidFailCurrentTrack:(PlaybackController *)playback {
    [self applyPlaybackLoadingToVisiblePages];
    [_waveformView hideLoadingIndicator];
}

#pragma mark - PlaybackObserver: deliveries

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row < 0) {
        return;
    }
    // Before the repaint: until this delivery the art dispatch is a message
    // to nil.
    if (NSLocationInRange((NSUInteger)row, [self artWindow])) {
        [self refreshArtWindow];
    }
    [self refreshPageAtIndex:(NSUInteger)row];
}

@end
