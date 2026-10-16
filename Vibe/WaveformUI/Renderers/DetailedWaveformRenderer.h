//
//  DetailedWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "WaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface DetailedWaveformRenderer : WaveformRenderer

// Wiggle shares the envelope's layers, progress and morph. wiggle:YES is
// valid only on this class, not on its bar-style subclasses.
- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                       wiggle:(BOOL)wiggle;

// The subclass hooks: the oversampled types override the column count; Basic
// the count, geometry and gradient.
//
// The Detailed types draw zoom steps' columns at this many a point: 2 here,
// and 4, 8 and 16 for the oversampled types, whose look is the sub-pixel
// overlap of more columns than pixels. 0 draws numBarsForWidth: bars instead,
// as Bars, Cupertino and Wiggle do.
- (double)columnsPerPoint;
- (NSUInteger)numBarsForWidth:(CGFloat)width;

// count interleaved, normalized [min, max] pairs for the columns of frames
// from first: the energy-scaled envelope here, ±level in Cupertino. The one
// hook behind every target, a step's columns or a style's bars.
- (void)fillColumns:(float *)out framesPerColumn:(double)frames first:(int64_t)first count:(NSUInteger)count
           waveform:(AudioWaveform *)waveform;

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count;

// color carries its side's resting level in its alpha; the hook owns only the
// ramp shape, every stop scaled relative to it (VibeColorWithScaledAlpha).
- (void)configureGradient:(CAGradientLayer *)gradient;
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark;

// Continuous here (Wiggle hovers a whole loop); Basic quantizes both to whole
// blocks. The seek stays continuous in every style.
- (CGFloat)playedClipWidthForProgress:(CGFloat)progress width:(CGFloat)width;
- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale;

@end

NS_ASSUME_NONNULL_END
