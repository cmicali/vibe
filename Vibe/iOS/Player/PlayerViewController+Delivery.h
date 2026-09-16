//
//  PlayerViewController+Delivery.h
//  Vibe (iOS)
//
//  Where the pager's asynchronous results land: waveform snapshots, and the
//  scrubber's seek. Both implement the one cross-directory guarantee about
//  deliveries racing track changes, which is why they are one file. The mac
//  twin is MainPlayerController+Delivery.
//
//  Metadata is not here: it is the model's delivery, not the pager's, so
//  PlaybackController takes it and the screen sees it as a PlaybackObserver
//  event.
//

#import "PlayerViewController.h"
#import "PageWaveformCoordinator.h"
#import "WaveformScrubberView.h"

NS_ASSUME_NONNULL_BEGIN

@class TrackPageCell;

@interface PlayerViewController (Delivery) <PageWaveformCoordinatorDelegate,
        WaveformScrubberViewDelegate>

// The waveform zoom is one value for the whole pager, and the scrubber's
// didChangeVisibleFraction: is what writes it — so its persistence lives here
// too, and the defaults key has exactly one home.

// Read the persisted zoom into _waveformZoom. Setup only.
- (void)restoreWaveformZoom;
// Push the shared zoom onto one page's scrubber; a no-op when it matches.
- (void)applyWaveformZoomToCell:(TrackPageCell *)cell;

@end

NS_ASSUME_NONNULL_END
