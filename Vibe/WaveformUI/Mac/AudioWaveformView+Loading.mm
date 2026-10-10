//
//  AudioWaveformView+Loading.mm
//  Vibe
//
//  When to show LoadingIndicator, and the empty line — that control at rest,
//  so it reads its height and colour from LoadingIndicatorMath.h.
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
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }
    _loadingIndicator = [[LoadingIndicator alloc]
            initInLayer:self.layer
                  style:VibeLoadingIndicatorStyleWaveform
                 isDark:self.isDark
          contentsScale:VibeBackingScaleOrDefault(self.window.backingScaleFactor)];
    [self layoutLoadingLayer];
}

- (void)layoutLoadingLayer {
    [_loadingIndicator layoutInBounds:self.bounds];
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

- (BOOL)isLoadingIndicatorShown {
    return _loadingIndicator != nil;
}

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
    line.contentsScale = VibeBackingScaleOrDefault(self.window.backingScaleFactor);
    [self.layer addSublayer:line];
    _placeholderLayer = line;

    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    CGFloat height = VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleWaveform, self.bounds.size.width).height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - height / 2,
                                         self.bounds.size.width, height);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    CGFloat alpha = VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleWaveform, self.bounds.size.width).trackAlpha;
    _placeholderLayer.backgroundColor =
            [base colorWithAlphaComponent:alpha].CGColor;
}

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

- (void)updateLoadingColors {
    [_loadingIndicator updateColorsForDark:self.isDark];
}

@end
