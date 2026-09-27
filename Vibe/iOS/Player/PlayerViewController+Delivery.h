//
//  PlayerViewController+Delivery.h
//  Vibe (iOS)
//
//  Where the pager's asynchronous results land: waveform snapshots and the
//  scrubber's events, each matched against the current track first. Metadata
//  is the model's delivery, a PlaybackObserver event.
//

#import "PlayerViewController.h"
#import "PageWaveformCoordinator.h"
#import "WaveformScrubberView.h"

NS_ASSUME_NONNULL_BEGIN

@class TrackPageCell;

@interface PlayerViewController (Delivery) <PageWaveformCoordinatorDelegate,
        WaveformScrubberViewDelegate>

// Holds the pager still for a scrub, a pinch or an FX pad hold, and releases
// it, matched against the view that took it (the trap on _pagerHoldView).
- (void)setPagerHeld:(BOOL)held byView:(UIView *)view;

// The pager's one zoom lives here beside its only writer,
// didChangeVisibleFraction:. Setup only.
- (void)restoreWaveformZoom;
// A no-op when it matches.
- (void)applyWaveformZoomToCell:(TrackPageCell *)cell;

@end

NS_ASSUME_NONNULL_END
