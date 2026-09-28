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

// The block styles' quantization: the block under a view x, and how many whole
// blocks a progress fills, each flipping at its midpoint. Presentation only —
// the reported seek stays continuous.
static inline NSInteger VibeBlockIndexForX(CGFloat x, CGFloat width, NSInteger count) {
    NSInteger index = (NSInteger)(x / width * (CGFloat)count);
    return clampRange(index, (NSInteger)0, count - 1);
}
static inline NSInteger VibeBlockBoundaryForProgress(CGFloat progress, NSInteger count) {
    NSInteger boundary = (NSInteger)llround((double)count * progress);
    return clampRange(boundary, (NSInteger)0, count);
}

// A bar's level averages energy over a column no finer than 1/1024 of the
// track (~0.4s, the momentary-loudness scale), however fine the bars: RMS over
// less than a beat converges back to peak, and the oversampling styles'
// one-chunk bars would peg on every kick. Only the level is floored; the
// min/max shape keeps per-bar resolution.
static const NSUInteger kVibeWaveformEnergyColumns = 1024;

// Split from the accessor below so a renderer caching per column keys on this
// index rather than re-deriving it.
static inline NSUInteger VibeWaveformEnergyColumnIndexForBar(NSUInteger i, NSUInteger count) {
    return count > kVibeWaveformEnergyColumns
            ? i * kVibeWaveformEnergyColumns / count : i;
}

// Every bar-level consumer maps through this, never its own chunk's energy,
// so bars finer than the column cannot re-peg to sub-beat RMS.
static inline AudioWaveformCacheChunk VibeWaveformEnergyColumnForBar(AudioWaveform *waveform,
                                                                     NSUInteger i,
                                                                     NSUInteger count) {
    return count > kVibeWaveformEnergyColumns
            ? waveform->getChunkAtIndex(VibeWaveformEnergyColumnIndexForBar(i, count),
                                        kVibeWaveformEnergyColumns)
            : waveform->getChunkAtIndex(i, count);
}

// Normalize only raises levels: its reference cannot exceed the fixed one.
// Match the drawn energy windows, including the finer styles' 1/1024 floor.
// Silence and empty waveforms keep the fixed reference to avoid division by zero.
// A streaming load keeps it too: its loudest column is only the loudest SO
// FAR, and a reference that rises per delivery shrinks bars already drawn.
static inline float VibeWaveformFullScaleRMSForWaveform(AudioWaveform * _Nullable waveform,
                                                        BOOL normalize,
                                                        NSUInteger count) {
    float loudest = (normalize && waveform && waveform->isFullyLoaded())
            ? sqrtf(waveform->getMaxMeanSquare(MIN(count, kVibeWaveformEnergyColumns))) : 0;
    return loudest > 0 ? fminf(loudest, kVibeWaveformFullScaleRMS) : kVibeWaveformFullScaleRMS;
}

// Pixel-snapped, since half-lit edge pixels blur the crispest thing in the
// waveform. Bounds-relative; x may overshoot either edge.
static inline CGRect VibeSnappedColumnRect(CGFloat x, CGFloat columnWidth,
                                           CGFloat boundsWidth, CGFloat height, CGFloat scale) {
    CGFloat width = MAX(round(columnWidth * scale), 1) / scale;
    CGFloat left = floor((x - width / 2) * scale) / scale;
    left = clampRange(left, 0, MAX(0, boundsWidth - width));
    return CGRectMake(left, 0, width, height);
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

// Basic, Cupertino and Sonic Cirrus share a 4pt pitch and a 1,024-bar cap.
- (NSUInteger)blockBarCountForWidth:(CGFloat)width;
- (CGFloat)scaledBarWidth:(CGFloat)width pitch:(CGFloat)pitch;

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

@end

NS_ASSUME_NONNULL_END
