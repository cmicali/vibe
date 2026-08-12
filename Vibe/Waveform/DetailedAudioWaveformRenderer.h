//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

@interface DetailedAudioWaveformRenderer : AudioWaveformRenderer

// The subclass hooks. The Oversampling x2, x4 and x8 variants override
// numBars, and Basic overrides the geometry and gradient hooks below.
// Everything else — the layer setup, hydration animation, progress clipping
// and mask caching — is shared.
//
// numBars is the rect count in the single CAShapeLayer mask path, not a CALayer
// count: 8,192 rects in one path is cheap, whereas 8,192 layers would not be.
- (NSUInteger)numBars;

// The bar geometry: the width of every bar, and the x origin of bar `index`.
- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count;
- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth;

// The gradient styling: its direction and extent, and the played and unplayed
// color stops. baseColor is white in dark mode and black in light.
- (void)configureGradient:(CAGradientLayer *)gradient;
- (NSArray<VibeColor *> *)playedGradientColors:(VibeColor *)baseColor isDark:(BOOL)isDark;
- (NSArray<VibeColor *> *)unplayedGradientColors:(VibeColor *)baseColor isDark:(BOOL)isDark;

- (void)setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<VibeColor*>*)colors;

@end
