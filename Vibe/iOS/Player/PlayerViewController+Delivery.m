//
//  PlayerViewController+Delivery.m
//  Vibe (iOS)
//
//  The coordinator matches waveform deliveries by sourceKey. Scrub events
//  apply only to the bound view. Pager holds release by the view that took them.
//

#import "PlayerViewController+Delivery.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Pager.h"

#import "AudioTrack.h"
#import "AudioWaveformCache.h"
#import "Formatters.h"
#import "PlaceholderFiles.h"
#import "PlaybackController+NowPlaying.h"
#import "VibePlaylist.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "WaveformZoomMath.h"

// iOS-only, so not AppSettings.
static NSString *const kWaveformZoomKey = @"VibeiOSWaveformZoom";

@implementation PlayerViewController (Delivery)

#pragma mark - PageWaveformCoordinatorDelegate

// The coordinator records completeness before it forwards, held or not.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index {
    BOOL complete = [pipeline isCompleteAtIndex:index];
    // Eased only where someone can see it: every eased frame is a full raster.
    [[self cellAtIndex:index].waveformView showWaveform:waveform animated:_sceneActive && self.isPresented];
    // Only a complete one: a widget bake is two renders and two file writes.
    if (complete) {
        [_playback offerWaveformToWidget:waveform
                                forTrack:[_playback.playlist trackAtIndex:index]];
    }
}

// A placeholder's refused open is not a failure to draw: its download will
// land and the open asks again. Only the current page's: a neighbor has no
// open coming to take the indicator down.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
      didFailWaveformForIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (track && index == _playback.currentIndex && [PlaceholderFiles isRemotePlaceholderFile:track.url]) {
        return;
    }
    [[self cellAtIndex:index].waveformView hideLoadingIndicator];
}

// The tempo is the model's to stamp and feed the taps; the page hears it back
// as the metadata event. No key: key detection is macOS-only.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
              didDetectBPM:(float)bpm
                  forTrack:(AudioTrack *)track {
    [_playback noteDetectedBPM:bpm forTrack:track];
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
    NSTimeInterval duration = VibePlayerScreenDuration(_playback.duration, _playback.currentTrack.duration);
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

// Deep zoom's frames, for the page bound to playback only: the view refills
// as they land. A neighbor is refused, and asks again when it next draws as
// the current page.
- (void)waveformScrubberView:(WaveformScrubberView *)view
           needsDetailBlocks:(NSIndexSet *)blocks
                  ofWaveform:(CodableAudioWaveform *)waveform {
    NSUInteger index = _playlist.currentIndex;
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (view != _waveformView || !track || [_waveformCoordinator snapshotAtIndex:index] != waveform) {
        [view detailDidLoadForWaveform:waveform];
        return;
    }
    __weak WaveformScrubberView *weakView = view;
    [_waveformCache loadDetailBlocks:blocks forTrack:track waveform:waveform completion:^{
        [weakView detailDidLoadForWaveform:waveform];
    }];
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
