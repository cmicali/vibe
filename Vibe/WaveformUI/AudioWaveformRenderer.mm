//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveformRenderer.h"

@implementation AudioWaveformRenderer {
    CGFloat _hoverHighlightX;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super init];
    if (self) {
        self.parentLayer = parentLayer;
        self.isDark = isDark;
        // A sentinel, forcing the first updateProgress: to paint every layer's
        // played or unplayed color rather than only the boundary delta.
        self.lastProgressBoundary = -1;
        _hoverHighlightX = -1;
    }
    return self;
}

- (CGFloat)hoverHighlightX {
    return _hoverHighlightX;
}

// Subclasses override this to paint, and call super to record the position.
- (void)setHoverHighlightX:(CGFloat)x {
    _hoverHighlightX = x;
}

// Abstract. Both are declared nonnull, and styleIdentifier is used as a
// dictionary key by AudioWaveformView's registry, so a subclass that forgets
// to override would otherwise raise deep inside -setup with nothing naming the
// culprit. Assert here, where the class is known, and return a marker that
// keeps a Release build registering something rather than crashing.
+ (NSString *)styleIdentifier {
    NSAssert(NO, @"%@ must override +styleIdentifier", NSStringFromClass(self));
    return NSStringFromClass(self);
}

+ (NSString *)displayName {
    NSAssert(NO, @"%@ must override +displayName", NSStringFromClass(self));
    return NSStringFromClass(self);
}

- (void)updateColors:(BOOL)isDark {
    self.isDark = isDark;
    // The colors have changed, so the cached played and unplayed colors on
    // every layer are stale. Force the next updateProgress: to repaint
    // everything.
    self.lastProgressBoundary = -1;
}

- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    NSAssert(NO, @"%@ must override seekHitBandForBounds:", NSStringFromClass(self.class));
    return bounds;
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *__nullable)waveform {

}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {

}

- (void)settleMorphImmediately {

}

- (void)backingScaleDidChange {

}

@end
