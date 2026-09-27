//
//  DetailedAudioWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface DetailedAudioWaveformRenderer : AudioWaveformRenderer

// Wiggle shares the envelope's layers, progress, morph and bitmap bake.
// wiggle:YES is valid only on this class, not on its bar-style subclasses.
- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                       wiggle:(BOOL)wiggle centered:(BOOL)centered;

// The subclass hooks: the oversampling variants override the count; Basic the
// count, geometry and gradient.
//
// The count follows the drawn width at the style's pitch; the oversampling
// variants keep fixed counts, since their look is the sub-pixel overlap of
// more rects than pixels. It counts rects in one mask path, not layers.
- (NSUInteger)numBarsForWidth:(CGFloat)width;

// count interleaved, normalized [min, max] pairs: the energy-scaled envelope
// here, ±level in Cupertino. The one hook behind both the live target and the
// bake, which must stay pixel-identical.
- (void)fillEnvelope:(float *)out barCount:(NSUInteger)count waveform:(AudioWaveform *)waveform;

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count;

// color carries its side's resting level in its alpha; the hook owns only the
// ramp shape, every stop scaled relative to it (VibeColorWithScaledAlpha).
- (void)configureGradient:(CAGradientLayer *)gradient;
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark;

// Continuous here (Wiggle hovers a whole loop); Basic quantizes both to whole
// blocks. The seek stays continuous in every style.
- (CGFloat)playedClipWidthForProgress:(CGFloat)progress width:(CGFloat)width;
- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale;

// The iOS scrubber's settled fast path: the whole envelope as one bitmap, so
// scrolling translates a texture instead of re-compositing the masked tree.
// While unplayedSharesPlayedHue the unplayed side is the played bitmap at
// unplayedOverPlayedOpacity; otherwise it bakes its own. Extract samples on
// main; the bakes touch no layer state and may run on any queue.
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
