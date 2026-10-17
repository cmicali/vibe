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
#include <array>
#include <atomic>
#include <memory>
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

// The mix styles' Normalize reference is the whole track's column: the
// waveform's own, so no view can move it. A streaming load keeps the fixed
// reference, which an empty column stands for. Its loudest window is only the
// loudest SO FAR, and a reference that rises per delivery shrinks bars
// already drawn.
static inline wavecore::Column VibeWaveformNormalizeColumn(AudioWaveform *waveform, BOOL normalize) {
    return normalize && waveform->isComplete() ? waveform->column(0, (double)waveform->totalFrames())
                                                : wavecore::Column();
}
// The mix styles' Normalize only raises levels: its reference cannot exceed
// the fixed one. Silence keeps the fixed reference.
static inline float VibeWaveformFullScaleRMSForWaveform(AudioWaveform *waveform, BOOL normalize) {
    float loudest = VibeWaveformNormalizeColumn(waveform, normalize).loudest;
    return loudest > 0 ? fminf(loudest, kVibeWaveformFullScaleRMS) : kVibeWaveformFullScaleRMS;
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
    // The layer frame its picture covers, in its bounds' points.
    CGRect frameForHeight(CGFloat height) const {
        return CGRectMake(x0 / scale, 0, (x1 - x0) / scale, height);
    }
    // The window the morph engine compares, in pixels.
    CGRect window() const {
        return CGRectMake(x0, 0, x1 - x0, height);
    }
};

// The space a picture is painted in: space, or sRGB for NULL.
CGColorSpaceRef VibePictureColorSpace(CGColorSpaceRef _Nullable space);

// A layer's picture from 32-bit premultiplied ARGB pixels in host order, in
// VibePictureColorSpace(space). TRAP: never an alpha-only image, even for a
// mask: one draws nothing under renderInContext:, which the registry's bake
// uses.
CGImageRef VibeNewImageWithPixels(NSMutableData *pixels, size_t width, size_t height,
                                  CGColorSpaceRef _Nullable space) CF_RETURNS_RETAINED;

// fill(pixels, rowStride) writes rows from the top of the picture. NULL when
// empty. TRAP: in a geometryFlipped tree (the iOS host) a layer shows its
// contents upside down, so for a layer whose contentsAreFlipped the rows are
// handed bottom-up, with a negative stride.
template <typename Fill>
static inline CGImageRef _Nullable VibeNewLayerImage(CGColorSpaceRef _Nullable space, BOOL flipped, size_t width,
                                                     size_t height, Fill fill) CF_RETURNS_RETAINED;
template <typename Fill>
static inline CGImageRef _Nullable VibeNewLayerImage(CGColorSpaceRef _Nullable space, BOOL flipped, size_t width,
                                                     size_t height, Fill fill) {
    if (width == 0 || height == 0) {
        return NULL;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * sizeof(uint32_t)];
    uint32_t *pixels = (uint32_t *)bytes.mutableBytes;
    ptrdiff_t stride = (ptrdiff_t)width;
    fill(flipped ? pixels + (height - 1) * width : pixels, flipped ? -stride : stride);
    return VibeNewImageWithPixels(bytes, width, height, space);
}

// A step style's picture, kept between rebuilds. A rebuild redraws only the
// pixel columns whose samples changed or that a moved window newly shows,
// and copies the rest from the picture before. While a waveform eases, the
// pixels are recycled once the layer lets an image go. A streaming load
// changes only its front, and an ease allocated and zeroed the whole picture
// 60 times a second.
class VibeStepPicture {
public:
    // Everything the raster reads but the samples and the window's pixels.
    // TRAP: a raster input left out of it draws stale wherever the samples
    // did not change.
    struct Look {
        int height = 0;
        CGFloat scale = 0;
        BOOL flipped = NO;
        double framesPerPixel = 0;
        int steps[2] = {0, 0};
        double coarse = 0;
        // The style's own switches and colors.
        std::array<float, 24> style = {};

        bool operator==(const Look &other) const {
            return height == other.height && scale == other.scale && flipped == other.flipped &&
                   framesPerPixel == other.framesPerPixel && steps[0] == other.steps[0] &&
                   steps[1] == other.steps[1] && coarse == other.coarse && style == other.style;
        }
    };

    // The picture of samples, laid out by window at stride floats a column,
    // over the window's pixels. raster(out, rowStride, x0, x1) draws pixel
    // columns [x0, x1) into cleared pixels, out at column x0's top row, and
    // writes no row outside [inkTop, inkBottom), rows from the top. NULL for
    // an empty window. Past drawShare of the picture to draw, it draws it
    // all, since copying the rest would cost more: each style's own, by
    // what its raster costs against a copy. recycle keeps the last picture's
    // pixels for the next: on while the samples ease, off at rest, where they
    // would only double the memory.
    // The raster is called here, inlined into its renderer, as a picture's
    // inner loop must be: called through a pointer it cost 3 to 9% more.
    template <typename Raster>
    CGImageRef _Nullable newImage(const Look &look, const VibeRenderPixels &pixels, const wavecore::StepWindow &window,
                        size_t stride, const std::vector<float> &samples, int inkTop, int inkBottom,
                        float drawShare, CGColorSpaceRef _Nullable space, bool recycle,
                        Raster raster) CF_RETURNS_RETAINED {
        Frame frame;
        if (!begin(frame, look, pixels, window, stride, samples, inkTop, inkBottom, drawShare)) {
            return NULL;
        }
        for (size_t i = 0; i < frame.dirtyCount; i++) {
            raster(frame.top + (frame.dirty[i].first - pixels.x0), frame.rowStride, frame.dirty[i].first,
                   frame.dirty[i].second);
        }
        return end(frame, look, pixels, window, stride, samples, space, recycle);
    }
    // Keeps nothing.
    void clear();

private:
    // Zeroed by calloc, so a fresh picture faults in only the pages it
    // inks, as a CFData's did.
    struct Pixels {
        std::unique_ptr<uint32_t[], void (*)(void *)> data{nullptr, free};
        size_t capacity = 0;
        // The pixels that may not be zero, as indices.
        size_t inkBegin = 0, inkEnd = 0;
        // Set while an image holds them; the image's release clears it.
        std::atomic<bool> held{false};
    };
    // A picture being drawn: its pixels, already holding what it keeps, and
    // the pixel columns left to draw.
    struct Frame {
        std::shared_ptr<Pixels> target;
        uint32_t *top = nullptr;
        ptrdiff_t rowStride = 0;
        std::array<std::pair<int, int>, 8> dirty;
        size_t dirtyCount = 0;
    };
    bool begin(Frame &frame, const Look &look, const VibeRenderPixels &pixels, const wavecore::StepWindow &window,
               size_t stride, const std::vector<float> &samples, int inkTop, int inkBottom, float drawShare);
    CGImageRef _Nullable end(Frame &frame, const Look &look, const VibeRenderPixels &pixels, const wavecore::StepWindow &window,
                   size_t stride, const std::vector<float> &samples, CGColorSpaceRef _Nullable space,
                   bool recycle) CF_RETURNS_RETAINED;
    static void releasePixels(void *info, const void *data, size_t size);

    std::shared_ptr<Pixels> shown_;
    std::shared_ptr<Pixels> spare_;
    Look look_;
    VibeRenderPixels pixels_;
    wavecore::StepWindow window_;
    size_t stride_ = 0;
    std::vector<float> samples_;
};

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
    // The columns fillLevels: last read, kept across fills so a resize
    // allocates none.
    std::vector<wavecore::Column> _fillColumns;
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

// The level of each column of count on the grid of frames from first, its
// loudest window with Normalize and Gain applied: Cupertino's, Sonic Cirrus'
// and Wiggle's. Stride permits interleaved envelopes; the caller supplies
// their sign and symmetry.
- (void)fillLevels:(float *)out stride:(NSUInteger)stride framesPerColumn:(double)frames
             first:(int64_t)first count:(NSUInteger)count waveform:(AudioWaveform *)waveform;
// The same for columns already read.
- (void)fillLevels:(float *)out stride:(NSUInteger)stride columns:(const wavecore::Column *)columns
             count:(NSUInteger)count waveform:(AudioWaveform *)waveform;

// The finest a zoom may show this style, in frames a point. Here the summary
// alone, and no wider than the width where the bars stop growing in number.
// The Detailed types reach the stream's own frames once it is complete.
- (double)minimumFramesPerPointForWaveform:(AudioWaveform *)waveform;

@property (strong) CALayer* parentLayer;

// The space a picture is painted in: its window's, set by the view. Core
// Animation then installs a picture as it is. It color-matched an sRGB one at
// every commit, half the main thread while a long file loaded on an external
// display. NULL, the default, is sRGB, which a picture drawn offscreen keeps.
@property (nonatomic, strong, nullable) __attribute__((NSObject)) CGColorSpaceRef pictureColorSpace;

// The part of the bounds to draw, in the parent's points; CGRectNull, the
// default, is the whole bounds. The iOS scrubber draws its visible stretch
// of a track far wider than the screen.
@property (nonatomic) CGRect renderRect;

// The render window for bounds of this size at the parent's scale.
- (VibeRenderPixels)renderPixelsForSize:(CGSize)size;
// The frames a pixel of _pixels covers, for a step style's _window.
- (double)framesPerPixel;

// The step styles' one target entry point, once _pixels is current. Reads the
// window's two steps at columnsPerPixel through fill, the morph's samples a
// column, part after part.
// Laid out by _window, the samples carry over a window or step change by the
// track's frames. A nil waveform keeps the last window and eases it to zero.
// Blocks of the stream landing in the waveform's detail refill it, and the
// columns ease to the finer picture.
- (void)updateStepTargetForSize:(CGSize)size waveform:(AudioWaveform * _Nullable)waveform
                columnsPerPixel:(double)columnsPerPixel
                           fill:(void (^)(float *out, const wavecore::StepPart &part))fill;

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
// the morph ease them back. A step style dips the columns under the track's
// span. No-op without a morph engine.
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
