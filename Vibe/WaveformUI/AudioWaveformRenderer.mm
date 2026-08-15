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

+ (NSString *)styleIdentifier {
    return nil;
}

+ (NSString *)displayName {
    return nil;
}

- (void)updateColors:(BOOL)isDark {
    self.isDark = isDark;
    // The colors have changed, so the cached played and unplayed colors on
    // every layer are stale. Force the next updateProgress: to repaint
    // everything.
    self.lastProgressBoundary = -1;
}

- (NSRect)seekHitBandForBounds:(NSRect)bounds {
    CGFloat bottomY = bounds.size.height/2 - (bounds.size.height/2 * .5);
    CGFloat topY = bounds.size.height/2 + (bounds.size.height/2 * .5);
    return NSMakeRect(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *__nullable)waveform {

}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {

}

- (void)backingScaleDidChange {

}

@end
