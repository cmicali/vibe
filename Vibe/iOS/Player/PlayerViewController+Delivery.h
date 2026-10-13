//
//  PlayerViewController+Delivery.h
//  Vibe (iOS)
//
//  Waveforms target their page. Scrub events target the bound view.
//  Metadata arrives through PlaybackObserver.
//

#import "PlayerViewController.h"
#import "PageWaveformCoordinator.h"
#import "WaveformScrubberView.h"

NS_ASSUME_NONNULL_BEGIN

@class TrackPageCell;

@interface PlayerViewController (Delivery) <PageWaveformCoordinatorDelegate,
        WaveformScrubberViewDelegate>

// Holds the pager still for a scrub, a pinch or an FX pad hold, and releases
// it, matched against the view that took it (the trap on _pagerHoldViews).
- (void)setPagerHeld:(BOOL)held byView:(UIView *)view;

// The pager's one zoom lives here beside its only writer,
// didChangeVisibleFraction:. Setup only.
- (void)restoreWaveformZoom;
// A no-op when it matches.
- (void)applyWaveformZoomToCell:(TrackPageCell *)cell;

@end

NS_ASSUME_NONNULL_END
