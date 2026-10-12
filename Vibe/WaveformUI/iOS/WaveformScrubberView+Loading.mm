//
//  WaveformScrubberView+Loading.mm
//  Vibe (iOS)
//
//  When to show LoadingIndicator, and the span of the view it covers.
//

#import "WaveformScrubberViewInternal.h"
#import "UIView+DarkMode.h"

@implementation WaveformScrubberView (Loading)

- (void)showLoadingIndicator {
    if (_loadingIndicator) {
        return;
    }
    if (!self.waveform) {
        [self resetWaveformContentState];
    }
    _loadingIndicator = [[LoadingIndicator alloc]
            initInLayer:self.layer
                  style:VibeLoadingIndicatorStyleWaveform
                 isDark:self.isDark
          contentsScale:[self displayScale]];
    [self layoutLoadingLayer];
}

// The span the track's content occupies, not the view's width: the off-track
// space stays empty. The full bounds before layout.
- (CGRect)loadingTrackBounds {
    CGFloat width = self.bounds.size.width;
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return self.bounds;
    }
    CGFloat centerX = width / 2;
    CGFloat progress = MAX(0.0, MIN(1.0, _progress));
    CGFloat left = MAX(0.0, centerX - progress * virtualWidth);
    CGFloat right = MIN(width, centerX + (1 - progress) * virtualWidth);
    if (right <= left) {
        return self.bounds;
    }
    return CGRectMake(left, 0, right - left, self.bounds.size.height);
}

- (void)layoutLoadingLayer {
    _loadingTrackBounds = [self loadingTrackBounds];
    [_loadingIndicator layoutInBounds:_loadingTrackBounds];
}

// Follows the playhead: showLoadingIndicator runs at progress 0, and the
// shell's next tick restores the real position.
//
// TRAP: keep the rect test. This is the one relayout that can land
// mid-download, and a duration-0 relayout snaps an easing fill to its target;
// while the provider materializes the file progress is parked, so the test
// declines.
- (void)syncLoadingTrackToProgress {
    if (!_loadingIndicator || CGRectEqualToRect([self loadingTrackBounds], _loadingTrackBounds)) {
        return;
    }
    [self layoutLoadingLayer];
}

// Not the fill: a disk-cached waveform can land while the provider is still
// materializing the audio, and the fill is the only sign of that. It comes
// down with its monitor, via setLoadingProgress:-1.
- (void)hideLoadingShimmer {
    if (_playbackLoading) {
        return;
    }
    if (![_loadingIndicator endSweepKeepingFill]) {
        [self hideLoadingIndicator];
    }
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

- (void)setLoadingProgress:(float)fraction {
    if (fraction >= 0 && !_loadingIndicator) {
        [self showLoadingIndicator];
    }
    _loadingTrackBounds = [self loadingTrackBounds];
    [_loadingIndicator setProgress:fraction inBounds:_loadingTrackBounds];
    if (_bakedHost) {
        [self hideLoadingShimmer];
    }
}

@end
