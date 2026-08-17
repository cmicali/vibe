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

#import "AudioTrack.h"
#import "Formatters.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "WaveformZoomMath.h"

// The waveform zoom, kept here rather than in AppSettings for the same reason
// FolderSession keeps its own two: it is an iOS-only value, and that class's
// platform split is one #if TARGET_OS_OSX block with no iOS-only side.
static NSString *const kWaveformZoomKey = @"VibeiOSWaveformZoom";

@implementation PlayerViewController (Delivery)

#pragma mark - PageWaveformCoordinatorDelegate

// Only the delivery that COMPLETES the waveform eases in. A streaming decode
// delivers about ten times a second, and easing each one kept the morph
// permanently retargeted and the baked fast path permanently pending, so the
// whole load ran on the live renderer tree — measured on device as 8 rotation
// hitches in 35s against 1 for a settled waveform. Partial deliveries therefore
// land settled, and the bars step forward as chunks arrive rather than growing.
//
// Nothing is lost by that: the scrubber draws the track zoomed past 2x, so most
// of what a morph would animate is off screen. And the case actually worth
// easing in still is — a disk-cached waveform arrives complete on its first and
// only delivery, so it takes this branch and morphs exactly as before.
//
// `isCompleteAtIndex:` is current here: the coordinator records completeness
// before it forwards, on the live path and on the held-update replay alike.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index {
    [[self cellAtIndex:index].waveformView showWaveform:waveform
                                              animated:[pipeline isCompleteAtIndex:index]];
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

// The scrub's target, in the time labels. The playhead is pinned at the view's
// center and never moves, so without this a drag gives no reading at all of
// where it will land — the waveform slides past and the labels keep counting
// the position still playing.
//
// The duration falls back to the track's own, as the seek path does: a parked
// track has none on the player, and scrubbing one is exactly how it gets
// opened at a position.
- (void)waveformScrubberView:(WaveformScrubberView *)view
          didScrubToProgress:(CGFloat)progress {
    if (view != _waveformView) {
        return;  // a neighbor page's preview waveform does not drive the chrome
    }
    NSTimeInterval duration = _playback.duration;
    if (duration <= 0) {
        duration = _playback.currentTrack.duration;
    }
    if (duration <= 0) {
        return;  // nothing to render against; the resting labels stand
    }
    NSTimeInterval position = MAX(0.0, MIN(1.0, progress)) * duration;
    // This arrives per frame of scroll and the labels show whole seconds.
    NSInteger second = (NSInteger)position;
    if (second == _scrubLabelSecond) {
        return;
    }
    _scrubLabelSecond = second;
    _elapsedLabel.text = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
    // In total-duration mode this does not move during a scrub, which is
    // correct: only the elapsed side tracks where the release will land.
    _remainingLabel.text = VibeRightTimeText(position, duration);
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
    // Whichever way this went, the labels' second guard is stale: a starting
    // scrub must render its first frame, and a finished one hands the labels
    // back to updatePlaybackUI at whatever the position turns out to be.
    _scrubLabelSecond = NSIntegerMin;
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

#pragma mark - Waveform zoom

// One zoom for the whole pager: every page's scrubber draws at it, so a swipe
// cannot change it and a page arriving mid-gesture comes up at the same depth.
- (void)waveformScrubberView:(WaveformScrubberView *)view
    didChangeVisibleFraction:(CGFloat)fraction {
    if (fraction == _waveformZoom) {
        return;
    }
    _waveformZoom = fraction;
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        [self applyWaveformZoomToCell:cell];
    }
    // The REQUEST is what is stored. Persisting what a view drew would let a
    // rotation, or a launch in the shallower orientation, permanently shallow
    // a zoom the other one could have shown.
    [NSUserDefaults.standardUserDefaults setDouble:fraction forKey:kWaveformZoomKey];
}

- (void)restoreWaveformZoom {
    // A missing key reads back as 0, which the clamp sends to the default
    // rather than to maximum zoom.
    _waveformZoom = VibeWaveformClampRequestedFraction(
            [NSUserDefaults.standardUserDefaults doubleForKey:kWaveformZoomKey]);
}

- (void)applyWaveformZoomToCell:(TrackPageCell *)cell {
    cell.waveformView.visibleFraction = _waveformZoom;
}

@end
