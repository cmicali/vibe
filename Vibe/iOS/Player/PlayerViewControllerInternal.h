//
//  PlayerViewControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared by PlayerViewController.m and its categories;
//  no other file imports it. The debug surface is
//  Debug/iOS/PlayerViewController+Debug.h. This header is the cost of the
//  split: a category that pushes more state in here than it takes out of
//  PlayerViewController.m is not worth making.
//

#import "PlayerViewController.h"
#import "FXPadView.h"
#import "OutputRouteView.h"
#import "PlaybackController.h"
#import "PlayerDisplaySettings.h"
#import "PlayerScreenRules.h"
#import "Playlist.h"

@class AudioTrack;
@class AudioWaveformCache;
@class PageWaveformCoordinator;
@class TrackPageActionBarView;
@class TrackPageCell;
@class TrackPageTimeControl;
@class WaveformScrubberView;

NS_ASSUME_NONNULL_BEGIN

// Every render path of the right time label goes through this.
NSString *VibeRightTimeText(NSTimeInterval position, NSTimeInterval duration);

// Every other conformance is declared on the category that implements it.
@interface PlayerViewController () <FXPadViewDelegate, OutputRouteViewDelegate,
        PlaybackObserver, UIGestureRecognizerDelegate> {
    PlaybackController      *_playback;
    // _playback's, held because every data-source callback reads it.
    Playlist                *_playlist;

    UICollectionView        *_pagesView;
    UICollectionViewFlowLayout *_pagesLayout;
    // Mid-resize the offset is not page-aligned, so commits hold.
    BOOL                    _windowResizeInFlight;
    // Dragging or decelerating; takes the frame-budget hold (+Pager).
    BOOL                    _pagerScrolling;
    // A visible programmatic page animation; minimized moves snap and never
    // set it.
    BOOL                    _pagerProgrammaticScrolling;
    // So a bounded release cannot lift a later take of the hold.
    uint64_t                _pagerProgrammaticScrollGeneration;
    CGSize                  _lastLayoutSize;

    // BINDINGS to the current page's views, rebound when its cell appears or
    // is recreated, so the live paths keep one stable name.
    TrackPageCell           *_boundPage;
    WaveformScrubberView    *_waveformView;
    UILabel                 *_elapsedLabel;
    TrackPageTimeControl    *_remainingTimeControl;
    UIView                  *_transportView;
    OutputRouteView         *_routeView;
    TrackPageActionBarView  *_actionBar;
    FXPadView               *_fxPadView;
    // The views holding the pager still — a scrubber mid-scrub or mid-pinch,
    // an FX pad under a finger — NOT always the bound page's: a track ending
    // mid-drag rebinds the chrome while the finger is down. A set, held
    // weakly: a scrub and a pad hold overlap, and the pager is free only
    // when the last of them lifts.
    NSHashTable<UIView *>   *_pagerHoldViews;

    // The pager's own, not the model's: nothing else draws a waveform.
    AudioWaveformCache      *_waveformCache;
    PageWaveformCoordinator *_waveformCoordinator;

    // Pages whose full-size art is held, the only record of what there is to
    // release: art outlives the window that asked for it. Owned by +Pager.
    NSMutableIndexSet       *_artHeldPages;

    // Here because the debug state dump reports it.
    BOOL                    _sceneActive;

    // The system route picker is up, which holds the playhead display link.
    // TRAP: AVKit does NOT reliably send the end edge (on the simulator,
    // never); stuck, the waveform freezes under correct labels for the life of
    // the process. A generation-stamped deadline releases it, and the
    // scene-active edge settles it sooner.
    BOOL                    _routePickerPresenting;
    uint64_t                _routePickerHoldGeneration;

    // The second last rendered for a scrub, so a drag does not format at
    // display rate. NSIntegerMin: not scrubbing.
    NSInteger               _scrubLabelSecond;

    // Shared by every page. The user's REQUEST, which is what persists; each
    // view applies its own floor (WaveformScrubberView.visibleFraction).
    CGFloat                 _waveformZoom;
}

#pragma mark - The refresh funnel

- (void)updatePlaybackUI;
- (void)updatePlayButton;
// Only the empty state hides the transport, action bar and route control.
- (CGFloat)chromeAlpha;
- (void)updateScrollLinkState;
- (void)updateOutputRoute;
// Refreshes the current page and rebinds the chrome to it.
- (void)renderHeaderForTrack:(nullable AudioTrack *)track;

#pragma mark - Resting time rendering

// Neighbor pages, a pending start and a parked track: 0:00, and the duration
// once metadata knows it.
+ (void)renderRestingTimesForTrack:(nullable AudioTrack *)track
                           elapsed:(UILabel *)elapsed
                         remaining:(TrackPageTimeControl *)remaining;
- (void)renderRestingTimesForTrack:(nullable AudioTrack *)track;

#pragma mark - Transport

- (void)playPauseTapped;
- (void)previousTapped;
- (void)nextTapped;
- (void)shuffleTapped;
- (void)repeatTapped;

// One setting for every page, so every visible page repaints.
- (void)remainingTimeTapped;

- (void)repaintTimesOnVisiblePages;

@end

NS_ASSUME_NONNULL_END
