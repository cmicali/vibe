//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

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
- (NSArray<NSColor *> *)playedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark;
- (NSArray<NSColor *> *)unplayedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark;

- (void)setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<NSColor*>*)colors;

// The iOS scrubber's settled fast path (see WaveformScrubberView): the whole
// envelope rendered once into a bitmap — the settled bar geometry filled with
// the played gradient, overall opacity included — so scrolling can translate
// a texture instead of re-compositing the masked live tree every frame. The
// unplayed presentation is the same bitmap at unplayedOverPlayedOpacity,
// which holds because this family's unplayed stops are the played stops
// scaled by one constant. Extract samples on the main thread; the bake itself
// touches no layer state and may run on any queue.
- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform;
- (nullable CGImageRef)newEnvelopeImageForSize:(CGSize)size
                                         scale:(CGFloat)scale
                                       samples:(NSData *)samples CF_RETURNS_RETAINED;
- (CGFloat)unplayedOverPlayedOpacity;

// The effective alpha of the hairline baseline at the vertical midline — the
// gradient's midpoint stop times the overall waveform opacity. The iOS
// scrubber colors its off-track baseline segments with it, so they read as
// the waveform's own centerline continuing past the track's ends.
- (CGFloat)baselineAlphaForPlayed:(BOOL)played;

@end

NS_ASSUME_NONNULL_END
