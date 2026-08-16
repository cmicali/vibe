//
//  PlayerViewController+Delivery.h
//  Vibe (iOS)
//
//  Where the pager's asynchronous results land: waveform snapshots, and the
//  scrubber's seek. Both implement the one cross-directory invariant about
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

@interface PlayerViewController (Delivery) <PageWaveformCoordinatorDelegate,
        WaveformScrubberViewDelegate>
@end

NS_ASSUME_NONNULL_END
