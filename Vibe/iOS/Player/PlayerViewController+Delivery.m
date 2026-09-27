//
//  PlayerViewController+Delivery.m
//  Vibe (iOS)
//
//  A delivery can arrive after the track has changed, so it is matched against
//  the current track (or the URL it was loaded for) before it is applied.
//

#import "PlayerViewController+Delivery.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Pager.h"

#import "AudioTrack.h"
#import "Formatters.h"
#import "PlaybackController+NowPlaying.h"
#import "Playlist.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "WaveformZoomMath.h"

// iOS-only, so not AppSettings.
static NSString *const kWaveformZoomKey = @"VibeiOSWaveformZoom";

@implementation PlayerViewController (Delivery)

#pragma mark - PageWaveformCoordinatorDelegate

// Only the COMPLETING delivery eases in. A streaming decode delivers ~10 Hz,
// and easing each keeps the morph retargeted and the bake pending for the
// whole load. A disk-cached waveform arrives complete, so it still morphs.
// The coordinator records completeness before it forwards, held or not.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index {
    BOOL complete = [pipeline isCompleteAtIndex:index];
    [[self cellAtIndex:index].waveformView showWaveform:waveform animated:complete];
    // Only a complete one: a widget bake is two renders and two file writes.
    if (complete) {
        [_playback offerWaveformToWidget:waveform
                                forTrack:[_playback.playlist trackAtIndex:index]];
    }
}

- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
      didFailWaveformForIndex:(NSUInteger)index {
    [[self cellAtIndex:index].waveformView hideLoadingIndicator];
}

// The tempo is the model's to stamp and feed the taps; the page hears it back
// as the metadata event. No key: key detection is macOS-only.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
              didDetectBPM:(float)bpm
                    forURL:(NSURL *)url {
    [_playback noteDetectedBPM:bpm forURL:url];
}

#pragma mark - WaveformScrubberViewDelegate

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage {
    if (view != _waveformView) {
        return;  // a neighbor's preview
    }
    [_playback seekToProgress:percentage];
}

// The labels show where the scrub will land, not what is still playing. The
// duration falls back to the track's own: a parked track has none on the
// player.
- (void)waveformScrubberView:(WaveformScrubberView *)view
          didScrubToProgress:(CGFloat)progress {
    if (view != _waveformView) {
        return;  // a neighbor's preview
    }
    NSTimeInterval duration = _playback.duration;
    if (duration <= 0) {
        duration = _playback.currentTrack.duration;
    }
    if (duration <= 0) {
        return;
    }
    NSTimeInterval position = MAX(0.0, MIN(1.0, progress)) * duration;
    NSInteger second = (NSInteger)position;
    if (second == _scrubLabelSecond) {
        return;
    }
    _scrubLabelSecond = second;
    _elapsedLabel.text = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
    _remainingTimeControl.text = VibeRightTimeText(position, duration);
}

// Holds the pager still for a scrub (the protocol says why).
// TRAP: the release is matched against the view that took the lock, not the
// bound page. A track ending mid-drag rebinds _waveformView while the finger
// is down on the outgoing page; filtering on the binding drops the lift and
// the pager stays unswipeable.
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing {
    // Either way the labels' second guard is stale.
    _scrubLabelSecond = NSIntegerMin;
    [self setPagerHeld:scrubbing byView:view];
}

- (void)setPagerHeld:(BOOL)held byView:(UIView *)view {
    if (held) {
        [_pagerHoldViews addObject:view];
    }
    else {
        [_pagerHoldViews removeObject:view];
    }
    // allObjects, not count, which still counts a holder that has died.
    _pagesView.scrollEnabled = _pagerHoldViews.allObjects.count == 0;
}

#pragma mark - Waveform zoom

// One zoom for the whole pager, so a swipe cannot change it.
- (void)waveformScrubberView:(WaveformScrubberView *)view
    didChangeVisibleFraction:(CGFloat)fraction {
    if (fraction == _waveformZoom) {
        return;
    }
    _waveformZoom = fraction;
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        [self applyWaveformZoomToCell:cell];
    }
    // The REQUEST: what a view drew would let a rotation permanently shallow
    // the zoom.
    [NSUserDefaults.standardUserDefaults setDouble:fraction forKey:kWaveformZoomKey];
}

- (void)restoreWaveformZoom {
    // A missing key reads 0, which the clamp sends to the default.
    _waveformZoom = VibeWaveformClampRequestedFraction(
            [NSUserDefaults.standardUserDefaults doubleForKey:kWaveformZoomKey]);
}

- (void)applyWaveformZoomToCell:(TrackPageCell *)cell {
    cell.waveformView.visibleFraction = _waveformZoom;
}

@end
