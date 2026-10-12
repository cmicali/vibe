//
//  AudioWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "PlatformTypes.h"
// C++ via AudioWaveform.h: import from .mm files only.
#import "AudioWaveform.h"
#import "WaveformTheme.h"
#import "WaveformLevelMath.h"
#import "WaveformBarMath.h"
#import "PlatformColor.h"

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// The backing scale before a real answer exists (no window yet, contentsScale
// unset). Every scale source goes through the clamp below, so the fallback
// cannot drift between sites.
static const CGFloat kVibeDefaultBackingScale = 2;

static inline CGFloat VibeBackingScaleOrDefault(CGFloat scale) {
    return scale > 0 ? scale : kVibeDefaultBackingScale;
}
static inline CGFloat VibeBackingScaleForLayer(CALayer * _Nullable layer) {
    return VibeBackingScaleOrDefault(layer.contentsScale);
}

// Normalize's reference is the loudest of the energy columns the bars draw,
// read from the mean squares the fill just took. A streaming load keeps the
// fixed reference: its loudest column is only the loudest SO FAR, and a
// reference that rises per delivery shrinks bars already drawn.
static inline float VibeWaveformFullScaleRMSForColumns(AudioWaveform *waveform, BOOL normalize,
                                                       const float *meanSquares, NSUInteger columns) {
    float loudest = 0;
    if (normalize && waveform->isComplete()) {
        vDSP_maxv(meanSquares, 1, &loudest, columns);
        loudest = sqrtf(fmaxf(loudest, 0));
    }
    return VibeWaveformNormalizedFullScaleRMS(loudest);
}

// Both styles' gradient: a ramp down the band, the resting level at the top
// and this share of it at the bottom. The live layer and the bake aim it
// here, so the two stay pixel-identical.
static const CGFloat kVibeBarGradientBottomAlpha = 0.45;
static inline NSArray<VibeColor *> *VibeBarRampColors(VibeColor *color, BOOL flat) {
    return @[color, flat ? color : VibeColorWithScaledAlpha(color, kVibeBarGradientBottomAlpha)];
}
// Grounded, every ramp's axis drops by half the band, as a share of the
// height: a bar's foot on the baseline reads the level its midline did, so
// quiet passages keep the brightness they had centered.
static inline CGFloat VibeBarRampDrop(BOOL centered) {
    return centered ? 0 : VibeBarVScale(1);
}
// y = 1 is the top.
static inline void VibeAimBarGradient(CAGradientLayer *gradient, BOOL centered) {
    CGFloat drop = VibeBarRampDrop(centered);
    gradient.startPoint = CGPointMake(0.5, 1 - VibeBarBaseline(1) - drop);
    gradient.endPoint = CGPointMake(0.5, VibeBarBaseline(1) - drop);
}
static inline void VibeFillBarGradient(CGContextRef ctx, CGSize size, NSArray *stops, BOOL centered) {
    CGGradientRef gradient = CGGradientCreateWithColors(CGBitmapContextGetColorSpace(ctx),
                                                        (__bridge CFArrayRef)stops, NULL);
    CGFloat drop = VibeBarRampDrop(centered);
    CGContextDrawLinearGradient(ctx, gradient,
            CGPointMake(0, size.height * (1 - VibeBarBaseline(1) - drop)),
            CGPointMake(0, size.height * (VibeBarBaseline(1) - drop)),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
}

// The envelope bake's bitmap, in the format the iOS scrubber installs: sRGB,
// premultiplied alpha first in host order, scaled to points. NULL when empty.
static inline CGContextRef _Nullable VibeNewEnvelopeBitmapContext(CGSize size, CGFloat scale) CF_RETURNS_RETAINED;
static inline CGContextRef _Nullable VibeNewEnvelopeBitmapContext(CGSize size, CGFloat scale) {
    size_t pixelWidth = (size_t)llround(size.width * scale);
    size_t pixelHeight = (size_t)llround(size.height * scale);
    if (pixelWidth == 0 || pixelHeight == 0) {
        return NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelWidth, pixelHeight, 8, 0, space,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (ctx) {
        CGContextScaleCTM(ctx, scale, scale);
    }
    return ctx;
}

// Both views own their layer trees, so a display change re-stamps them here,
// masks and all.
static inline void VibeApplyContentsScale(CALayer * _Nullable layer, CGFloat scale) {
    if (!layer) {
        return;
    }
    layer.contentsScale = scale;
    VibeApplyContentsScale(layer.mask, scale);
    for (CALayer *sublayer in layer.sublayers) {
        VibeApplyContentsScale(sublayer, scale);
    }
}

@class WaveformMorphEngine;

@interface AudioWaveformRenderer : NSObject {
@protected
    // Bar renderers install their geometry callback; flat controls leave this nil.
    WaveformMorphEngine *_morph;
}

@property (assign) BOOL isDark;

// The view resolves it and must call updateColors: after setting it; init
// defaults it to Mono for isDark. isDark stays separate for non-palette
// decisions.
@property (strong) WaveformTheme *theme;

// Normalize and Gain, handed over by the view; off and 0 dB are the plain
// mapping. Either setter invalidates the morph target, so the bars ease to
// their new heights rather than keeping the last fill's.
@property (nonatomic) BOOL normalizesLevels;
@property (nonatomic) float gainDB;

// Multiplier of the designed count; defaults to 1. Detailed and the pill ignore it.
@property (nonatomic) CGFloat barDensity;
// Multiplier of bar/stroke thickness, independent of count; defaults to 1.
@property (nonatomic) CGFloat barWidthScale;
// YES, the default, draws about the midline; NO grounds every bar on a baseline
// at the foot of the band, the height it had about the midline. Sonic Cirrus
// and the pill ignore it (WaveformRendererRegistry.supportsCenteringForIdentifier:).
@property (nonatomic) BOOL centered;

// Basic, Cupertino and Sonic Cirrus share a 4pt pitch and a 1,024-bar cap.
- (NSUInteger)blockBarCountForWidth:(CGFloat)width;
- (CGFloat)scaledBarWidth:(CGFloat)width pitch:(CGFloat)pitch;

// The energy columns' levels for count bars, Normalize and Gain applied: the
// one sampling every bar style but 3-Band draws its levels from. Bar i draws
// column VibeWaveformEnergyColumnIndexForBar(i, count).
- (std::vector<float>)energyColumnLevelsForBarCount:(NSUInteger)count waveform:(AudioWaveform *)waveform;

// One energy level per bar. Stride permits interleaved envelopes without a
// temporary sample buffer; the caller supplies their sign and symmetry.
- (void)fillEnergyLevels:(float *)out count:(NSUInteger)count stride:(NSUInteger)stride
               waveform:(AudioWaveform *)waveform;

@property (strong) CALayer* parentLayer;

// Wiggle's loop count can use an unzoomed reference width while its geometry
// spans the drawn width. Zero follows the drawn width; other styles ignore it.
@property (nonatomic) CGFloat samplingWidth;

// Metadata for the class's default registry entry. Variants may share a class;
// persist and compare the resolved registry identifier, never this class key.
// displayName is localized and must never be used as a key.
+ (NSString *)styleIdentifier;

// Localized, user-visible name. Display only.
+ (NSString *)displayName;

// Whether the style draws the bands, which a waveform holds only when its
// decode was asked for them. NO here.
+ (BOOL)readsBands;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

// The vertical band a click must land in to seek, from the bounds alone. Every
// renderer must override it; the base only asserts.
- (CGRect)seekHitBandForBounds:(CGRect)bounds;

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

// Rebuilds the morph geometry, whose pixel snapping baked in the old scale and
// which a same-size updateWaveform: skips.
- (void)backingScaleDidChange;

// The Convert to FLAC sweep: dip the bars in [from, to) to the midline and let
// the morph ease them back. No-op without a morph engine.
- (void)dipBarsFromFraction:(double)from toFraction:(double)to;

// See WaveformMorphEngine.settleImmediately. No-op without a morph engine.
- (void)settleMorphImmediately;

// Lights the waveform's own column at view x; negative clears. Kept so a
// resize or morph rebuild can reposition it; the base only stores it.
- (void)setHoverHighlightX:(CGFloat)x;
@property (readonly) CGFloat hoverHighlightX; // < 0 when not hovering

// Whether the envelope bake is pixel-identical to the live tree. A subclass
// that changes its gradient aim or played-fill quantization must answer for
// itself — why Basic answers NO despite subclassing Detailed.
@property (readonly) BOOL supportsEnvelopeBake;

// The bake, for a style that supports it: the iOS scrubber's settled fast
// path draws the whole envelope as one bitmap, so scrolling translates a
// texture instead of re-compositing the live tree. Extract samples on main;
// the bakes touch no layer state and may run on any queue.
- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform;
- (nullable CGImageRef)newEnvelopeImageForSize:(CGSize)size
                                         scale:(CGFloat)scale
                                       samples:(NSData *)samples CF_RETURNS_RETAINED;
// NULL when the unplayed side is the played bitmap at
// unplayedOverPlayedOpacity, which halves the bake's bytes.
- (nullable CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size
                                                 scale:(CGFloat)scale
                                               samples:(NSData *)samples CF_RETURNS_RETAINED;
- (CGFloat)unplayedOverPlayedOpacity;

// How much taller Normalize draws a complete waveform than the fixed
// reference draws it while it streams: the whole picture scales by it, since a
// level is linear in the reference below the clamp, which Normalize keeps
// clear of. 1 where Normalize changes nothing.
- (CGFloat)normalizationGainForWaveform:(AudioWaveform *)waveform;

@end

NS_ASSUME_NONNULL_END
