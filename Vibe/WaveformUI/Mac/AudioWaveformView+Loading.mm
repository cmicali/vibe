//
//  AudioWaveformView+Loading.mm
//  Vibe
//
//  The view's two non-waveform presentations. The loading control itself is
//  WaveformLoadingIndicator, shared with the iOS scrubber; what is left here
//  is when to show it, and the empty state's static line — which is that same
//  control at rest, so it takes its height and colour from WaveformMidline.h
//  rather than restating them.
//

#import "AudioWaveformView+Loading.h"
#import "AudioWaveformViewInternal.h"
#import "NSView+DarkMode.h"

@implementation AudioWaveformView (Loading)

- (void)showLoadingIndicator {
    if (_loadingIndicator) {
        return;
    }
    [self hideEmptyPlaceholder];
    // Collapse any previous track's waveform, so the shimmer stands alone.
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }
    _loadingIndicator = [[WaveformLoadingIndicator alloc]
            initInLayer:self.layer
                 isDark:self.isDark
          contentsScale:VibeBackingScaleForWindow(self.window)];
    [self layoutLoadingLayer];
}

// The control's frame depends on the current bounds, so a helper keeps it in
// sync when the window resizes, or the small-large layout toggles, mid-load.
- (void)layoutLoadingLayer {
    [_loadingIndicator layoutInBounds:self.bounds];
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

// Fed by DownloadProgressMonitor for a materializing cloud file; the control
// owns the easing and the indeterminate revert. See WaveformLoadingIndicator.
- (void)setLoadingProgress:(float)fraction {
    [_loadingIndicator setProgress:fraction inBounds:self.bounds];
}

#pragma mark - The empty state

- (void)showEmptyPlaceholder {
    if (_placeholderLayer) {
        return;
    }
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CALayer *line = [CALayer layer];
    line.contentsScale = VibeBackingScaleForWindow(self.window);
    [self.layer addSublayer:line];
    _placeholderLayer = line;

    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

// The same midline the loading indicator uses, full-width and static: the
// empty state is that control at rest, so it shares the height and colour.
- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - kVibeMidlineHeight / 2,
                                         self.bounds.size.width, kVibeMidlineHeight);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    _placeholderLayer.backgroundColor =
            [base colorWithAlphaComponent:kVibeInertMidlineAlpha].CGColor;
}

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

// Re-asserted when the window flips between light and dark. Unconditional: the
// indicator re-colours whether or not one is currently up.
- (void)updateLoadingColors {
    [_loadingIndicator updateColorsForDark:self.isDark];
}

@end
