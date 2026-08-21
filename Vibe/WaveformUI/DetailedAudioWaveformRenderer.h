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

// The gradient styling: its direction and extent, and the ramp's color stops.
// color is the theme's played or unplayed color, carrying its side's resting
// level in its alpha; the hook owns only the ramp shape, every stop scaled
// relative to that level (VibeColorAtRampFraction). One hook serves both
// sides — the played/unplayed difference is entirely the colors' levels.
- (void)configureGradient:(CAGradientLayer *)gradient;
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark;

- (void)setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<VibeColor*>*)colors;

// The iOS scrubber's settled fast path (see WaveformScrubberView): the whole
// envelope rendered once into a bitmap — the settled bar geometry filled with
// the played gradient, overall opacity included — so scrolling can translate
// a texture instead of re-compositing the masked live tree every frame. While
// the theme's unplayed hue is the played hue (unplayedSharesPlayedHue), the
// unplayed presentation is that same bitmap at unplayedOverPlayedOpacity —
// the ratio of the two colors' resting alphas, valid because both sides share
// the ramp shape; a two-hue theme bakes the unplayed variant separately with
// its own stops and shows it at full opacity. Extract samples on the main
// thread; the bakes touch no layer state and may run on any queue.
- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform;
- (nullable CGImageRef)newEnvelopeImageForSize:(CGSize)size
                                         scale:(CGFloat)scale
                                       samples:(NSData *)samples CF_RETURNS_RETAINED;
- (nullable CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size
                                                 scale:(CGFloat)scale
                                               samples:(NSData *)samples CF_RETURNS_RETAINED;
- (CGFloat)unplayedOverPlayedOpacity;

@end

NS_ASSUME_NONNULL_END
