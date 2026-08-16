//
//  PlayerViewController+Delivery.h
//  Vibe (iOS)
//
//  Where asynchronous results land: metadata, waveform snapshots, detected BPM
//  and key, plus the scrubber's seek. All of them implement the one
//  cross-directory invariant about deliveries racing track changes, which is
//  why they are one file. The mac twin is MainPlayerController+Delivery.
//

#import "PlayerViewController.h"
#import "AudioTrackMetadataCache.h"
#import "PageWaveformCoordinator.h"
#import "WaveformScrubberView.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlayerViewController (Delivery) <AudioTrackMetadataCacheDelegate,
        PageWaveformCoordinatorDelegate, WaveformScrubberViewDelegate>
@end

NS_ASSUME_NONNULL_END
