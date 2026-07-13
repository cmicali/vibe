//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

@interface DetailedAudioWaveformRenderer : AudioWaveformRenderer

// Subclass hooks — the Oversampling x2/x4/x8 variants override numLayers,
// and Basic overrides the geometry/gradient hooks below. Everything else
// (layer setup, hydration animation, progress clipping, mask caching) is
// shared.
- (NSUInteger)numLayers;

// Bar geometry: the width of every bar, and the x origin of bar `index`.
- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count;
- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth;

// Gradient styling: direction/extent, and the played/unplayed color stops
// (baseColor is white in dark mode, black in light).
- (void)configureGradient:(CAGradientLayer *)gradient;
- (NSArray<NSColor *> *)playedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark;
- (NSArray<NSColor *> *)unplayedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark;

@end
