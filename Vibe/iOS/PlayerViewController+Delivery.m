//
//  PlayerViewController+Delivery.m
//  Vibe (iOS)
//
//  See PlayerViewController+Delivery.h. Every method here implements the same
//  cross-directory invariant: a delivery can arrive after the track has
//  changed, so it is matched against the current track (or the URL it was
//  loaded for) before it is applied.
//

#import "PlayerViewController+Delivery.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Pager.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "TrackListViewController.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Delivery)

#pragma mark - AudioTrackMetadataCacheDelegate

- (void)didLoadMetadata:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row >= 0) {
        [_trackListController reloadTrackAtIndex:(NSUInteger)row];
        // Before the repaint. This delivery installs the metadata object the
        // art dispatch hangs off — until it lands the dispatch is a message to
        // nil — so a page inside the window that could not start its decode
        // starts it here, and the repaint below finds art rather than the
        // placeholder as soon as it arrives.
        [self refreshArtWindow];
        [self refreshPageAtIndex:(NSUInteger)row];
    }
    if ([_playlist isCurrentTrack:track]) {
        // The full refresh, not just the publish: a parked track's time
        // labels render from this delivery's duration.
        [self updatePlaybackUI];
    }
}

#pragma mark - PageWaveformCoordinatorDelegate

- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index {
    [[self cellAtIndex:index].waveformView showWaveform:waveform];
}

// No BPM or key delivery here: analysis is macOS-only, so the coordinator has
// nothing to forward. AudioTrack.bpm and .key still resolve, from the file's
// own tags.

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

@end
