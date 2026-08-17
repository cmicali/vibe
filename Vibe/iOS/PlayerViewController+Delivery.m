//
//  PlayerViewController+Delivery.m
//  Vibe (iOS)
//
//  See PlayerViewController+Delivery.h. Both methods here implement the same
//  cross-directory guarantee: a delivery can arrive after the track has
//  changed, so it is matched against the current track (or the URL it was
//  loaded for) before it is applied.
//

#import "PlayerViewController+Delivery.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Pager.h"

#import "TrackPageCell.h"
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Delivery)

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
    [_playback seekToProgress:percentage];
}

// Hold the pager still for the length of a scrub. See the protocol comment:
// while an enclosing scroll view can still scroll the way the finger is going,
// UIKit chains the scrubber's overscroll into it and the band never appears —
// so the ends bounced on the last page and clamped everywhere else.
//
// TRAP: the release is matched against the view that took the lock, not
// against the bound page. Playback runs on through a scrub — the seek only
// commits on lift — so a track ending mid-drag rebinds _waveformView to the
// next page while the finger is still down on the outgoing one. Filtering the
// lift on the binding drops it, and the pager stays unswipeable.
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing {
    if (scrubbing) {
        _scrubbingView = view;
    }
    else if (view != _scrubbingView) {
        return;  // a page that never held the lock, or a reset of a still cell
    }
    else {
        _scrubbingView = nil;
    }
    _pagesView.scrollEnabled = !scrubbing;
}

@end
