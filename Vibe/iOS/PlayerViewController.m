//
//  PlayerViewController.m
//  Vibe (iOS)
//
//  The coordination: the chrome it builds, the update funnel, the empty state,
//  and the PlaybackController events it draws. Everything else is a category —
//  see PlayerViewControllerInternal.h for the surface they share.
//

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlayerViewController+Pager.h"

#import "AudioTrack.h"
#import "AudioWaveformCache.h"
#import "PageWaveformCoordinator.h"
#import "TrackPageCell.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "VibeWeakProxy.h"
#import "WaveformMidline.h"   // the empty line IS the scrubber's placeholder
#import "WaveformScrubberView.h"

// The pager must not take a horizontal drag that starts on a waveform: the
// scrubber owns those.
//
// TRAP: making the pager's pan require the scrubber's to fail is not enough.
// When the scrubber's scroll sits exactly at a content edge, UIKit's nested
// scroll arbitration keeps its pan from beginning at all so an ancestor scroll
// view can have the gesture — the failure requirement is satisfied and the
// pager inherits the drag, so pushing against an end either turned the page or,
// on a one-track playlist, did nothing. Declining by hit-test here is what
// leaves the drag with the scrubber. It has to be an override rather than a
// delegate, since a scroll view owns its own pan's delegate.
@interface VibeTrackPagerView : UICollectionView
@end

@implementation VibeTrackPagerView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == self.panGestureRecognizer) {
        UIView *hit = [self hitTest:[recognizer locationInView:self] withEvent:nil];
        for (UIView *view = hit; view && view != self; view = view.superview) {
            if ([view isKindOfClass:[WaveformScrubberView class]]) {
                return NO;
            }
        }
    }
    return [super gestureRecognizerShouldBegin:recognizer];
}
@end

@implementation PlayerViewController {
    // Drives the scrolling waveform at display rate while playing in the
    // foreground; the model's 3 Hz tick is far too coarse for a moving
    // waveform.
    CADisplayLink           *_scrollLink;

    // The affordance for the swipe that minimizes the card, and a tap target
    // that does the same.
    UIView                  *_grabberView;
    UIView                  *_grabberTarget;
    UITapGestureRecognizer  *_screenTap;
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
    // Forced dark, like the Apple Music and SoundCloud player screens: every
    // label and the waveform must read over arbitrary blurred art.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Before buildUI, so the first cell to display already has it.
    [self restoreWaveformZoom];
    [self buildUI];

    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCoordinator = [[PageWaveformCoordinator alloc] initWithCache:_waveformCache delegate:self];
    _artHeldPages = [NSMutableIndexSet indexSet];

    _foreground = YES;
    _scrollLink = [CADisplayLink displayLinkWithTarget:[VibeWeakProxy proxyWithTarget:self]
                                              selector:@selector(scrollTick:)];
    // ~1pt/frame of motion gains nothing at 120 Hz; spare ProMotion the work.
    _scrollLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    _scrollLink.paused = YES;
    [_scrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    [_playback addObserver:self];

    // The display link is the only thing here the background gates; the
    // model's own tick is gated by PlaybackController.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(sceneDidEnterBackground)
                   name:UISceneDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(sceneWillEnterForeground)
                   name:UISceneWillEnterForegroundNotification object:nil];
    // The settings screen lives on the Playlist tab, with this one minimized
    // behind it, so the change arrives from outside rather than from a control
    // of ours.
    [center addObserver:self selector:@selector(displaySettingsDidChange)
                   name:VibeDisplaySettingsDidChangeNotification object:nil];
}

// All three settings at once, since a screen that writes one may have written
// any of them: the header carries the file-info line, the scrubbers carry the
// waveform style, and the right label carries the time mode. Only the visible
// pages need it — a cell in the reuse pool is configured from scratch on its
// way back on screen.
- (void)displaySettingsDidChange {
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        NSIndexPath *path = [_pagesView indexPathForCell:cell];
        if (path) {
            [self configurePage:cell atIndex:(NSUInteger)path.item];
        }
        [cell.waveformView syncWaveformStyle];
    }
    [self repaintTimesOnVisiblePages];
}

- (void)sceneDidEnterBackground {
    _foreground = NO;
    [self updateScrollLinkState];
}

- (void)sceneWillEnterForeground {
    _foreground = YES;
    [self updateScrollLinkState];
    [self updatePlaybackUI];
}

// Reachable because the display link holds the weak proxy, not the
// controller; the invalidate releases the link's run-loop registration.
- (void)dealloc {
    [_scrollLink invalidate];
}

#pragma mark - The right time label's mode

NSString *VibeRightTimeText(NSTimeInterval position, NSTimeInterval duration) {
    Formatters *formatters = [Formatters sharedInstance];
    if (!VibeShowsRemainingTime()) {
        return [formatters durationStringFromTimeInterval:duration];
    }
    // Same spelling as the mac's renderRightTimeLabel: a literal minus, not a
    // localized one — it is arithmetic notation, not prose.
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
    _pagesView = [[VibeTrackPagerView alloc] initWithFrame:CGRectZero
                                    collectionViewLayout:_pagesLayout];
    _pagesView.pagingEnabled = YES;
    _pagesView.showsHorizontalScrollIndicator = NO;
    _pagesView.allowsSelection = NO;
    // A two-finger touch on this screen is a waveform zoom, never a page swipe.
    _pagesView.panGestureRecognizer.maximumNumberOfTouches = 1;
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

    // The grabber: the sheet affordance, and the tap that minimizes.
    _grabberView = [[UIView alloc] init];
    _grabberView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.35];
    _grabberView.layer.cornerRadius = 2.5;
    _grabberView.isAccessibilityElement = YES;
    _grabberView.accessibilityTraits = UIAccessibilityTraitButton;
    _grabberView.accessibilityLabel = STR_A11Y_PLAYER_MINIMIZE;
    _grabberView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_grabberView];

    // A hit area a finger can find: the bar itself is five points tall.
    UIView *grabberTarget = [[UIView alloc] init];
    grabberTarget.backgroundColor = UIColor.clearColor;
    grabberTarget.translatesAutoresizingMaskIntoConstraints = NO;
    [grabberTarget addGestureRecognizer:
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(minimizeTapped)]];
    [root addSubview:grabberTarget];
    _grabberTarget = grabberTarget;

    // Tap anywhere (off the waveform and the controls) — the art card
    // included — toggles play/pause, the whole page standing in for the
    // transport row's middle button.
    _screenTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(screenTapped)];
    _screenTap.delegate = self;
    [root addGestureRecognizer:_screenTap];

    // Swipe down to minimize. It has to beat the pager to the touch, or a
    // horizontally-paging scroll view — whose pan begins on movement in ANY
    // direction — would swallow every vertical drag. The axis test in
    // gestureRecognizerShouldBegin: fails this recognizer on the first move of
    // a horizontal drag, so a page swipe pays one touch event for the
    // arbitration and nothing more.
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
    // At rest the position is 0, so remaining is the whole duration — but it
    // still goes through the one rule, or a page at rest would show a bare
    // total while a playing one showed a minus-prefixed remaining.
    remaining.text = known ? VibeRightTimeText(0, track.duration) : STR_LABEL_TIME_UNKNOWN;
}

- (void)renderRestingTimesForTrack:(AudioTrack *)track {
    [PlayerViewController renderRestingTimesForTrack:track
                                              elapsed:_elapsedLabel
                                            remaining:_remainingLabel];
}

#pragma mark - Gestures

// Downward, and more vertical than horizontal. Anything else is a page swipe,
// and failing here is what hands the touch back to the pager.
//
// TRAP: the test is on TRANSLATION, not velocity. Velocity is sampled over the
// last few touch events and reads zero whenever the finger pauses — including
// the moment a slow, deliberate drag crosses the recognizer's slop, which is
// exactly when this is asked. Translation is monotonic and always past the
// slop by the time this runs.
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
    // The waveforms own horizontal drags and taps for scrubbing, and the
    // controls own their touches; the screen tap applies everywhere else.
    // Class membership, not frames: every page cell carries a waveform view
    // in its own coordinate space.
    //
    // The transport ROW is declined as a whole, not just its buttons: a
    // disabled button is not handed back by hit-testing, so next at the end of
    // the playlist would otherwise pass its tap through to the pause below it.
    for (UIView *view = touch.view; view && view != self.view; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]
                || [view isKindOfClass:[VibeTransportRowView class]]
                || [view isKindOfClass:[VibeTimeLabel class]]
                || [view isKindOfClass:[WaveformScrubberView class]]
                || (view == _grabberTarget && gestureRecognizer != _minimizePan)) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Presentation

- (void)setPresented:(BOOL)presented {
    if (_presented == presented) {
        return;
    }
    _presented = presented;
    [self updateScrollLinkState];
    if (presented) {
        // Minimized the card takes no ticks, so its labels, waveform and page
        // are however the last one left them.
        [self updatePlaybackUI];
        [self renderHeaderForTrack:_playlist.currentTrack];
        [self scrollToCurrentPageAnimated:NO];
    }
}

#pragma mark - Header rendering

// The pager owns the header, art, and waveform; rendering the current track
// means refreshing its page and rebinding the live chrome to it.
- (void)renderHeaderForTrack:(AudioTrack *)track {
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
        _transportView = nil;
    }
}

- (void)updatePlayButton {
    [_boundPage setGlyphPlaying:_playback.isPlaying];
    [self updateChrome];
}

// The transport stays up whatever the play state — it is the page's controls,
// not a paused-state affordance. The empty state is the one thing that hides
// it: there is nothing to play until a folder is chosen.
- (CGFloat)chromeAlpha {
    return _playback.screenState == VibePlayerScreenStateEmpty ? 0 : 1;
}

- (void)updateChrome {
    CGFloat rowAlpha = [self chromeAlpha];
    if (_transportView.alpha == rowAlpha) {
        return;
    }
    [UIView animateWithDuration:0.3 animations:^{
        self->_transportView.alpha = rowAlpha;
    }];
}

// Paused unless the playhead is actually moving where someone can see it. A
// page swipe counts as nowhere: the waveform translating a fraction of a pixel
// under a page that is itself sliding across the screen is invisible, and the
// frames it costs are exactly the ones the swipe needs. A size transition
// counts as nowhere for the same reason and a sharper one — the bake is down
// for its duration, so each of those writes is a full re-composite of the live
// tree rather than a texture crop. Both are the frame-budget hold; see
// applyFrameBudgetHold in +Pager.
- (void)updateScrollLinkState {
    _scrollLink.paused = !(_playback.isPlaying && _foreground && self.isPresented
                           && !_pagerScrolling && !_windowResizeInFlight);
}

- (void)scrollTick:(CADisplayLink *)link {
    if (self.presentedViewController) {
        // A sheet covers the waveform strip. The per-frame translation of the
        // multi-screen layer tree is invisible waste, and it competes with the
        // sheet + keyboard presentation for exactly the frames that stutter on
        // device; the model's 3 Hz tick keeps progress near-current for the
        // reveal.
        return;
    }
    if (_waveformView.isScrubbing) {
        return;
    }
    // The seek target is checked FIRST, ahead of Loading. A seek that opens the
    // file — the parked scrub — is Loading and in flight at the same time, and
    // zeroing the waveform there is exactly the snap-back the seek target
    // exists to prevent. An ordinary track change clears seekInFlight, so
    // Loading still wins where it should.
    if (_playback.seekInFlight) {
        _waveformView.progress = _playback.pendingSeekProgress;
        return;
    }
    if (_playback.screenState == VibePlayerScreenStateLoading) {
        _waveformView.progress = 0;
        return;
    }
    NSTimeInterval duration = _playback.duration;  // non-blocking, like position
    if (duration > 0) {
        _waveformView.progress = _playback.position / duration;
    }
}

- (void)updatePlaybackUI {
    if (_waveformView.isScrubbing) {
        // The scrub owns the whole readout for its duration: the waveform,
        // which it moves under the finger, and the labels, which show where
        // the release will land rather than what is still playing
        // (didScrubToProgress:). Same bail as scrollTick:, one tier up.
        return;
    }
    if (VibePlayerScreenRendersRestingTimes(_playback.screenState)) {
        // Same precedence as scrollTick:: a seek in flight is a better answer
        // for where the playhead is than "at rest".
        if (_playback.seekInFlight && !_waveformView.isScrubbing) {
            _waveformView.progress = _playback.pendingSeekProgress;
            [self renderRestingTimesForTrack:_playlist.currentTrack];
            return;
        }
        // The current track at rest — the neighbor-page treatment. Loading: the
        // player's getters still serve the OUTGOING track. Parked (a relaunch
        // restore): the player has nothing loaded, and without this the labels
        // sat at --:-- even after metadata delivered the duration.
        [self renderRestingTimesForTrack:_playlist.currentTrack];
        if (!_waveformView.isScrubbing) {
            _waveformView.progress = 0;
        }
        return;
    }
    NSTimeInterval position = _playback.position;
    NSTimeInterval duration = _playback.duration;
    if (duration > 0) {
        Formatters *formatters = [Formatters sharedInstance];
        _elapsedLabel.text = [formatters durationStringFromTimeInterval:position];
        _remainingLabel.text = VibeRightTimeText(position, duration);
        // The display link owns the waveform while playing; this 3 Hz write
        // is the only one while paused or parked, and they agree otherwise.
        if (!_waveformView.isScrubbing && !_playback.seekInFlight) {
            _waveformView.progress = position / duration;
        }
    }
    else {
        _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
        _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
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

- (void)remainingLabelTapped {
    VibeSetShowsRemainingTime(!VibeShowsRemainingTime());
    [self repaintTimesOnVisiblePages];
}

// Every visible page, not just the one that changed: the neighbors are drawn
// at rest and would keep the old spelling until they were recycled.
- (void)repaintTimesOnVisiblePages {
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        if (cell == _boundPage) {
            continue;   // the bound page is live; updatePlaybackUI has it
        }
        NSInteger index = [_pagesView indexPathForCell:cell].item;
        if (index >= 0 && (NSUInteger)index < (NSInteger)_playlist.count) {
            [PlayerViewController renderRestingTimesForTrack:[_playlist trackAtIndex:(NSUInteger)index]
                                                     elapsed:cell.elapsedLabel
                                                   remaining:cell.remainingLabel];
        }
    }
    [self updatePlaybackUI];
}

- (void)screenTapped {
    // The grabber is the minimize target, the transport buttons own their own
    // touches; everywhere else — the art card included — toggles play/pause.
    [_playback playPause];
}

- (void)minimizeTapped {
    [self.delegate playerViewControllerDidRequestMinimize:self];
}

#pragma mark - PlaybackObserver: the playlist

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    // The art window's indexes, the snapshots and the pages all name tracks
    // that are gone.
    [_artHeldPages removeAllIndexes];
    [_waveformCoordinator reset];
    [_pagesView reloadData];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [_pagesView reloadData];
}

// Nothing here for a cursor move: the pages are drawn by renderHeaderForTrack:
// and scrolled by playbackDidMoveToCurrentTrack:, and no art is discarded —
// the departing track is usually the page right beside the arriving one, and
// releasing its decode on every commit made a swipe back re-read and re-decode
// the file. The art window owns retention, and renderHeaderForTrack: moves it.

#pragma mark - PlaybackObserver: the current track

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    [self scrollToCurrentPageAnimated:animated];
    [self requestWaveformForIndex:playback.currentIndex];
    [_waveformCoordinator pruneAroundIndex:playback.currentIndex];
}

- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback {
    [self renderHeaderForTrack:playback.currentTrack];
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self updateScrollLinkState];
    [self updatePlayButton];
}

- (void)playbackDidTick:(PlaybackController *)playback {
    [self updatePlaybackUI];
}

#pragma mark - PlaybackObserver: the current track's open

- (void)playbackDidBeginLoading:(PlaybackController *)playback {
    [_waveformView showLoadingIndicator];
}

- (void)playback:(PlaybackController *)playback didUpdateLoadingProgress:(float)fraction {
    [_waveformView setLoadingProgress:fraction];
}

// Not a blanket hideLoadingIndicator: the open landing says nothing about the
// waveform decode, which may still be streaming over the network.
// Re-hydration repaints a snapshot already in hand (ending the slow-open
// shimmer that replaced it); otherwise the line keeps animating until
// showWaveform: delivers. The download fill IS cleared here — the open
// landing means the file materialized, and showWaveform: deliberately leaves
// the fill alone (a cached waveform can arrive mid-download).
- (void)playbackDidFinishLoading:(PlaybackController *)playback {
    TrackPageCell *cell = [self cellAtIndex:playback.currentIndex];
    [cell.waveformView setLoadingProgress:-1];
    [self hydrateWaveformInCell:cell atIndex:playback.currentIndex];
}

- (void)playbackDidFailCurrentTrack:(PlaybackController *)playback {
    [_waveformView hideLoadingIndicator];
}

#pragma mark - PlaybackObserver: deliveries

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row < 0) {
        return;
    }
    // Before the repaint. This delivery installs the metadata object the art
    // dispatch hangs off — until it lands the dispatch is a message to nil —
    // so a page inside the window that could not start its decode starts it
    // here, and the repaint below finds art rather than the placeholder as
    // soon as it arrives.
    [self refreshArtWindow];
    [self refreshPageAtIndex:(NSUInteger)row];
}

@end
