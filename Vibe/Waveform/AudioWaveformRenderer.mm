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
        // Sentinel: force the first updateProgress: to paint every layer's
        // played/unplayed color, not just the boundary delta.
        self.lastProgressBoundary = -1;
        _hoverHighlightX = -1;
    }
    return self;
}

- (CGFloat)hoverHighlightX {
    return _hoverHighlightX;
}

// Subclasses override to paint, calling super to record the position.
- (void)setHoverHighlightX:(CGFloat)x {
    _hoverHighlightX = x;
}

+ (NSString *)displayName {
    return nil;
}

- (void)updateColors:(BOOL)isDark {
    self.isDark = isDark;
    // Colors changed — the cached played/unplayed colors on every layer are
    // now stale. Force the next updateProgress: to repaint everything.
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

@end
