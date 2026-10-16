//
//  WaveformRenderer.h
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

#include "WaveformRaster.hpp"
#include <utility>
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

// Normalize's reference is the track's loudest energy column, by default of
// its 1,024: the waveform's own, so no view's width can move it. A grid that
// a zoom step fixes may measure its own. A streaming load keeps the fixed
// reference: its loudest column is only the loudest SO FAR, and a reference
// that rises per delivery shrinks bars already drawn.
static inline float VibeWaveformFullScaleRMSForWaveform(AudioWaveform *waveform, BOOL normalize,
                                                        NSUInteger columns = kVibeWaveformEnergyColumns,
                                                        float reach = 0) {
    float loudest = 0;
    if (normalize && waveform->isComplete() && columns > 0) {
        waveform->loudestMeanSquares(columns, reach, &loudest, NULL);
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

// Where a renderer draws, in device pixels: columns [x0, x1) of its bounds'
// width at scale, and the rows of its height.
struct VibeRenderPixels {
    int x0 = 0;
    int x1 = 0;
    int height = 0;
    CGFloat scale = 1;

    int width() const { return x1 - x0; }
    bool operator==(const VibeRenderPixels &other) const {
        return x0 == other.x0 && x1 == other.x1 && height == other.height && scale == other.scale;
    }
    // The layer frame its picture covers, in its bounds' points.
    CGRect frameForHeight(CGFloat height) const {
        return CGRectMake(x0 / scale, 0, (x1 - x0) / scale, height);
    }
};

// A layer's picture from 32-bit premultiplied ARGB pixels in host order.
// TRAP: never an alpha-only image, even for a mask: one draws nothing under
// renderInContext:, which the registry's bake uses.
CGImageRef VibeNewImageWithPixels(NSMutableData *pixels, size_t width, size_t height) CF_RETURNS_RETAINED;

// fill(pixels, rowStride) writes rows from the top of the picture. NULL when
// empty. TRAP: in a geometryFlipped tree (the iOS host) a layer shows its
// contents upside down, so for a layer whose contentsAreFlipped the rows are
// handed bottom-up, with a negative stride.
template <typename Fill>
static inline CGImageRef _Nullable VibeNewLayerImage(BOOL flipped, size_t width, size_t height,
                                                     Fill fill) CF_RETURNS_RETAINED;
template <typename Fill>
static inline CGImageRef _Nullable VibeNewLayerImage(BOOL flipped, size_t width, size_t height, Fill fill) {
    if (width == 0 || height == 0) {
        return NULL;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * sizeof(uint32_t)];
    uint32_t *pixels = (uint32_t *)bytes.mutableBytes;
    ptrdiff_t stride = (ptrdiff_t)width;
    fill(flipped ? pixels + (height - 1) * width : pixels, flipped ? -stride : stride);
    return VibeNewImageWithPixels(bytes, width, height);
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

// Places the lit hover column, or hides it for CGRectNull. Over the played
// side the lit column hides and a hole in played shows the unplayed side
// (Mac/AGENTS.md). column is in the superlayer's coordinates, which played
// shares. Callers disable actions.
static inline void VibePlaceHoverColumn(CALayer *lit, CALayer *played, CGRect column) {
    BOOL hovering = !CGRectIsNull(column);
    BOOL overPlayed = hovering && CGRectGetMidX(column) < played.bounds.size.width;
    if (hovering) {
        lit.frame = column;
    }
    lit.hidden = !hovering || overPlayed;
    if (!overPlayed) {
        played.mask = nil;
        return;
    }
    CAShapeLayer *hole = (CAShapeLayer *)played.mask;
    if (!hole) {
        hole = [CAShapeLayer layer];
        hole.fillRule = kCAFillRuleEvenOdd;
        hole.contentsScale = played.contentsScale;
        played.mask = hole;
    }
    // The superlayer's whole area, so the hole still covers played as it grows.
    CGRect area = {CGPointZero, played.superlayer.bounds.size};
    hole.frame = area;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, area);
    CGPathAddRect(path, NULL, column);
    hole.path = path;
    CGPathRelease(path);
}

@class WaveformMorphEngine;

@interface WaveformRenderer : NSObject {
@protected
    // Bar renderers install their geometry callback; flat controls leave this nil.
    WaveformMorphEngine *_morph;
    // Where the samples land: the window's device pixels, and for a step
    // style the columns the samples hold.
    VibeRenderPixels _pixels;
    wavecore::StepWindow _window;
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

// The level of each column of count on the grid of frames from first,
// Normalize and Gain applied: the one energy reading of every style but
// 3-Band and Spectrum. Stride permits interleaved envelopes; the caller
// supplies their sign and symmetry.
- (void)fillEnergyLevels:(float *)out stride:(NSUInteger)stride framesPerColumn:(double)frames
                   first:(int64_t)first count:(NSUInteger)count waveform:(AudioWaveform *)waveform;
// count bars across the whole track.
- (void)fillEnergyLevels:(float *)out count:(NSUInteger)count stride:(NSUInteger)stride
               waveform:(AudioWaveform *)waveform;

@property (strong) CALayer* parentLayer;

// The part of the bounds to draw, in the parent's points; CGRectNull, the
// default, is the whole bounds. The iOS scrubber draws its visible stretch
// of a track far wider than the screen.
@property (nonatomic) CGRect renderRect;

// The render window for bounds of this size at the parent's scale.
- (VibeRenderPixels)renderPixelsForSize:(CGSize)size;
// The frames a pixel of _pixels covers, for a step style's _window.
- (double)framesPerPixel;

// The step styles' one target entry point, once _pixels is current. Reads the
// window's two steps at columnsPerPixel through fill, stride floats a column,
// part after part.
// Laid out by _window, the samples carry over a window or step change by the
// track's frames. A nil waveform keeps the last window and eases it to zero.
- (void)updateStepTargetForSize:(CGSize)size waveform:(AudioWaveform * _Nullable)waveform
                columnsPerPixel:(double)columnsPerPixel stride:(NSUInteger)stride
                           fill:(void (^)(float *out, const wavecore::StepPart &part))fill;
// The convert sweep over a step style's columns.
- (void)dipStepColumnsFromFraction:(double)from toFraction:(double)to stride:(NSUInteger)stride;

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
// decode was asked for them. A style that paints a band palette reads them.
+ (BOOL)readsBands;

// The palette the style paints, which the settings then offer. The waveform
// theme's here.
+ (VibeWaveformPaletteKind)paletteKind;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

// The vertical band a click must land in to seek, from the bounds alone. Every
// renderer must override it; the base only asserts.
- (CGRect)seekHitBandForBounds:(CGRect)bounds;

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

// Draws the picture again at the parent's new scale, which a same-size
// updateWaveform: would skip. The samples keep their columns, which are a
// number a point.
- (void)backingScaleDidChange;

// The Convert to FLAC sweep: dip the bars in [from, to) to the midline and let
// the morph ease them back. No-op without a morph engine.
- (void)dipBarsFromFraction:(double)from toFraction:(double)to;

// See WaveformMorphEngine.settleImmediately. No-op without a morph engine.
- (void)settleMorphImmediately;
// Whether the samples rest on their target; always without a morph engine.
@property (readonly, getter=isSettled) BOOL settled;

// Lights the waveform's own column at view x; negative clears. Kept so a
// resize or morph rebuild can reposition it; the base only stores it.
- (void)setHoverHighlightX:(CGFloat)x;
@property (readonly) CGFloat hoverHighlightX; // < 0 when not hovering

@end

NS_ASSUME_NONNULL_END
