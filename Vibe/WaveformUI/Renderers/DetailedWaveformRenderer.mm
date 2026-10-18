//
//  DetailedWaveformRenderer.mm
//  Vibe
//

#import "DetailedWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "PlatformTypes.h"
#import "PlatformColor.h"
#import "VibeStrings.h"
#import "WaveformZoomMath.h"

#include <vector>
#include <cmath>

static const CGFloat kWiggleStrokeWidth = 1.5;
static const CGFloat kWigglePitch = 8;
static const NSUInteger kWiggleMaxLoops = 1024;

static CGFloat VibeWiggleStrokeForSize(CGSize size, NSUInteger count, CGFloat widthScale) {
    return MIN(kWiggleStrokeWidth, size.width / (MAX((NSUInteger)1, count) * 4)) * widthScale;
}

static CGFloat VibeWiggleVScale(CGFloat height, BOOL centered, CGFloat widthScale) {
    return MAX(0, VibeBarVScale(height) * 2 - kWiggleStrokeWidth * widthScale) / (centered ? 2 : 1);
}

// The centerline only: a filled outline makes every resize and morph frame pay
// for a second, much larger path.
static CGPathRef VibeNewWigglePath(CGSize size, const float *samples, NSUInteger count,
                                  BOOL centered, CGFloat widthScale, CGRect window) CF_RETURNS_RETAINED;
static CGPathRef VibeNewWigglePath(CGSize size, const float *samples, NSUInteger count,
                                  BOOL centered, CGFloat widthScale, CGRect window) {
    CGMutablePathRef line = CGPathCreateMutable();
    CGFloat stroke = VibeWiggleStrokeForSize(size, count, widthScale);
    CGFloat amplitude = VibeWiggleVScale(size.height, centered, widthScale);
    if (count == 0 || size.width <= stroke || amplitude == 0) return line;
    CGFloat baseline = centered ? size.height / 2 : VibeBarBaseline(size.height) + stroke / 2;
    CGFloat pitch = (size.width - stroke) / count;
    CGFloat radiusX = pitch / 4;
    const CGFloat kCircleControl = 0.5522847498;
    // Keep a loop beyond each stroke edge. The clipped path's caps and joins
    // then stay outside the picture, including its antialiased edge.
    NSUInteger first = (NSUInteger)MAX(0, floor((CGRectGetMinX(window) - stroke - 1) / pitch) - 1);
    NSUInteger end = (NSUInteger)MIN((CGFloat)count, ceil((CGRectGetMaxX(window) + stroke + 1) / pitch) + 1);
    first = MIN(first, count);
    CGFloat bottom = baseline - (centered && first > 0 && first < count
            ? clampRange(samples[first * 2 + 1], 0, 1) * amplitude : 0);
    CGPathMoveToPoint(line, NULL, first ? stroke / 2 + (first - 1) * pitch + pitch : stroke / 2, bottom);
    for (NSUInteger i = first; i < end; i++) {
        CGFloat x = stroke / 2 + i * pitch;
        CGFloat height = clampRange(samples[i * 2 + 1], 0, 1) * amplitude;
        CGFloat top = baseline + height;
        CGFloat nextBottom = baseline - (centered && i + 1 < count
                ? clampRange(samples[(i + 1) * 2 + 1], 0, 1) * amplitude : 0);
        CGFloat radiusY = MIN(radiusX, (top - bottom) / 2);
        CGFloat cx = radiusX * kCircleControl, cy = radiusY * kCircleControl;
        CGPathAddCurveToPoint(line, NULL, x + cx, bottom,
                             x + radiusX, bottom + radiusY - cy,
                             x + radiusX, bottom + radiusY);
        CGPathAddLineToPoint(line, NULL, x + radiusX, top - radiusY);
        CGPathAddCurveToPoint(line, NULL, x + radiusX, top - radiusY + cy,
                             x + 2 * radiusX - cx, top, x + 2 * radiusX, top);
        radiusY = MIN(radiusX, (top - nextBottom) / 2);
        cy = radiusY * kCircleControl;
        CGPathAddCurveToPoint(line, NULL, x + 2 * radiusX + cx, top,
                             x + 3 * radiusX, top - radiusY + cy,
                             x + 3 * radiusX, top - radiusY);
        CGPathAddLineToPoint(line, NULL, x + 3 * radiusX, nextBottom + radiusY);
        CGPathAddCurveToPoint(line, NULL, x + 3 * radiusX, nextBottom + radiusY - cy,
                             x + pitch - cx, nextBottom, x + pitch, nextBottom);
        bottom = nextBottom;
    }
    return line;
}

// Each column's [min, max] as y-up pixels: adding the negative min preserves
// DC-offset asymmetry; grounded, the bar keeps its height on the baseline.
// Whole pixels only when settled, or the motion would move in steps.
static void VibeFillSpans(float *bottoms, float *tops, const float *samples, size_t count, CGFloat height,
                          CGFloat minimumHeight, BOOL centered, BOOL snap) {
    CGFloat midY = height / 2, baseline = VibeBarBaseline(height), vscale = VibeBarVScale(height);
    for (size_t i = 0; i < count; i++) {
        CGFloat lo = samples[i * 2], hi = samples[i * 2 + 1];
        CGFloat top = centered ? midY + hi * vscale : baseline + (hi - lo) * vscale;
        CGFloat bottom = centered ? midY + lo * vscale : baseline;
        if (snap) {
            top = round(top);
            bottom = round(bottom);
        }
        bottoms[i] = (float)bottom;
        tops[i] = (float)(bottom + MAX(top - bottom, minimumHeight));
    }
}

@implementation DetailedWaveformRenderer {
    BOOL _wiggle;
    // One mask for the whole stack: masking each gradient would rasterize and
    // ship the same picture twice per morph frame.
    CALayer *_waveformContainer;      // mask: _barMask; holds both gradients
    // Its contents are the picture's coverage over the render window.
    CALayer *_barMask;
    CAGradientLayer *_unplayedGradient;

    // masksToBounds; its width is the playhead.
    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;

    // Inside _waveformContainer, so the bar mask clips it to the envelope: the
    // lit slice is the waveform, not a line over it.
    CALayer *_hoverColumn;

    // Kept across morph frames and fills, so neither allocates.
    std::vector<float> _bottoms;
    std::vector<float> _tops;
    std::vector<wavecore::Column> _columns;
    std::vector<float> _levels;
    std::unique_ptr<wavecore::ColumnCoverage> _coverage;
    VibeStepPicture _picture;
}

+ (NSString *)styleIdentifier {
    return @"detailed";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_DETAILED;
}

- (double)columnsPerPoint {
    return _wiggle ? 0 : 2;
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    if (self.samplingWidth > 0) width = self.samplingWidth;
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) * self.barDensity / kWigglePitch);
    return clampRange(count, (NSUInteger)2, kWiggleMaxLoops);
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return width / (CGFloat)count;
}

- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    return VibeBarSeekHitBand(bounds);
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    return [self initWithLayer:parentLayer bounds:bounds isDark:isDark wiggle:NO];
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                       wiggle:(BOOL)wiggle {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        NSAssert(!wiggle || self.class == DetailedWaveformRenderer.class,
                 @"Wiggle variants require DetailedWaveformRenderer's geometry hooks");
        _wiggle = wiggle;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) {
                    return wiggle ? VibeWiggleVScale(height, weakSelf.centered, weakSelf.barWidthScale)
                                  : VibeBarVScale(height);
                }
                       rebuild:^{ [weakSelf rebuildMask]; }];
        _morph.samplesPerBar = 2;
        [self setupGradientLayers];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)setupGradientLayers {
    CGFloat scale = self.parentLayer.contentsScale;

    // Mask updates always run with actions disabled: every morph is the
    // timer-driven rebuild, never a Core Animation contents fade.
    _waveformContainer = [CALayer layer];
    _waveformContainer.anchorPoint = CGPointZero;
    _waveformContainer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
    _waveformContainer.contentsScale = scale;
    _barMask = [CALayer layer];
    _barMask.contentsScale = scale;
    _waveformContainer.mask = _barMask;
    [self.parentLayer addSublayer:_waveformContainer];

    _unplayedGradient = [CAGradientLayer layer];
    _unplayedGradient.contentsScale = scale;
    [self configureGradient:_unplayedGradient];
    [_waveformContainer addSublayer:_unplayedGradient];

    _playedClip = [CALayer layer];
    _playedClip.masksToBounds = YES;
    _playedClip.anchorPoint = CGPointZero;
    _playedClip.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
    _playedClip.contentsScale = scale;

    _playedGradient = [CAGradientLayer layer];
    _playedGradient.contentsScale = scale;
    [self configureGradient:_playedGradient];
    [_playedClip addSublayer:_playedGradient];
    [_waveformContainer addSublayer:_playedClip];

    // Last, so it composites over both gradients.
    _hoverColumn = [CALayer layer];
    _hoverColumn.anchorPoint = CGPointZero;
    _hoverColumn.actions = @{@"bounds": [NSNull null], @"position": [NSNull null],
                             @"hidden": [NSNull null], @"backgroundColor": [NSNull null]};
    _hoverColumn.contentsScale = scale;
    _hoverColumn.hidden = YES;
    [_waveformContainer addSublayer:_hoverColumn];
}

// Pinned to the bars' band rather than the full view, so the whole ramp lands
// across the visible bars.
- (void)configureGradient:(CAGradientLayer *)gradient {
    VibeAimBarGradient(gradient, self.centered);
}

// The ramp's aim follows the anchoring, and so do Cupertino's colors.
- (void)setCentered:(BOOL)centered {
    if (self.centered == centered) return;
    [super setCentered:centered];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self configureGradient:_playedGradient];
    [self configureGradient:_unplayedGradient];
    [self updateColors:self.isDark];
    [CATransaction commit];
}

- (void)dealloc {
    [_waveformContainer removeFromSuperlayer];
}

- (NSArray *)gradientCGColorsForColor:(VibeColor *)color {
    NSArray<VibeColor *> *colors = [self gradientColorsForColor:color isDark:self.isDark];
    NSMutableArray *cgColors = [[NSMutableArray alloc] initWithCapacity:colors.count];
    for (VibeColor *color in colors) {
        [cgColors addObject:(id)color.CGColor];
    }
    return cgColors;
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    _playedGradient.colors = [self gradientCGColorsForColor:self.theme.playedColor];
    _unplayedGradient.colors = [self gradientCGColorsForColor:self.theme.unplayedColor];
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
}

// The color's resting alpha at the top, kVibeBarGradientBottomAlpha of it at
// the bottom; one shape for both sides and both appearances.
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark {
    return VibeBarRampColors(color, self.theme.flatFill);
}

- (void)setHoverHighlightX:(CGFloat)x {
    [super setHoverHighlightX:x];
    if (!_hoverColumn || !self.parentLayer) {
        return;
    }
    CGRect b = self.parentLayer.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    VibePlaceHoverColumn(_hoverColumn, _playedClip, x < 0 || b.size.width <= 0 ? CGRectNull
            : [self hoverColumnRectForX:x bounds:b scale:VibeBackingScaleForLayer(self.parentLayer)]);
    [CATransaction commit];
}

- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale {
    if (_wiggle) {
        NSUInteger count = [self numBarsForWidth:bounds.size.width];
        CGFloat stroke = VibeWiggleStrokeForSize(bounds.size, count, self.barWidthScale);
        CGFloat width = MAX(0, bounds.size.width - stroke);
        NSUInteger index = (NSUInteger)VibeBlockIndexForX(x - stroke / 2,
                                                          width, (NSInteger)count);
        CGFloat pitch = width / count;
        CGFloat left = floor(index * pitch * scale) / scale;
        CGFloat right = ceil(((index + 1) * pitch + stroke) * scale) / scale;
        return CGRectMake(left, 0, right - left, bounds.size.height);
    }
    return VibeSnappedColumnRect(x, kVibeHoverHighlightWidth,
                                 bounds.size.width, bounds.size.height, scale);
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    if (!_playedClip || !self.parentLayer) return;
    CGRect b = self.parentLayer.bounds;
    _playedClip.bounds = CGRectMake(0, 0, [self playedClipWidthForProgress:progress width:b.size.width],
                                    b.size.height);
    _playedClip.position = CGPointZero;
    // The playhead can cross a still cursor.
    if (self.hoverHighlightX >= 0) {
        [self setHoverHighlightX:self.hoverHighlightX];
    }
}

- (CGFloat)playedClipWidthForProgress:(CGFloat)progress width:(CGFloat)width {
    CGFloat w = width * progress;
    return clampRange(w, 0, width);
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    // Implicit animations would leave the waveform chasing an animated window
    // resize. _playedClip's actions dictionary already disables its own.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _waveformContainer.frame = localBounds;
    _unplayedGradient.frame = localBounds;
    _playedGradient.frame = localBounds;
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];

    _pixels = [self renderPixelsForSize:bounds.size];
    double columnsPerPoint = [self columnsPerPoint];
    if (columnsPerPoint > 0) {
        [self updateStepTargetForSize:bounds.size waveform:waveform
                      columnsPerPixel:[self columnsPerPixelForWaveform:waveform width:bounds.size.width]
                                 fill:^(float *out, const wavecore::StepPart &part) {
            [self fillColumns:out framesPerColumn:part.framesPerColumn() first:part.first count:part.count
                     waveform:waveform];
        }];
    } else {
        NSUInteger count = [self numBarsForWidth:bounds.size.width];
        [_morph updateTargetForSize:bounds.size window:_pixels.window() identity:waveform count:count * 2
                               fill:^(std::vector<float> &target) {
            [self fillColumns:target.data() framesPerColumn:(double)waveform->totalFrames() / (double)count
                        first:0 count:count waveform:waveform];
        }];
    }
}

// The oversampled types' columns a pixel, but none finer than a pixel once
// they are finer than a bin. There a column is a slice of the stream's own
// line, and a pixel holding several draws the mean of their slices, so the
// line went faint. Over the bins every column holds its whole bin. The floor
// rises with the zoom, so the step moves continuously.
- (double)columnsPerPixelForWaveform:(AudioWaveform *)waveform width:(CGFloat)width {
    double columnsPerPixel = [self columnsPerPoint] / _pixels.scale;
    double pixels = width * _pixels.scale;
    if (waveform && pixels > 0 && columnsPerPixel > 1) {
        double framesPerPixel = (double)waveform->totalFrames() / pixels;
        double framesPerColumn = framesPerPixel / columnsPerPixel, bin = waveform->binFrames();
        if (framesPerColumn < bin) {
            columnsPerPixel = framesPerPixel / fmax(framesPerColumn, fmin(bin, framesPerPixel));
        }
    }
    return columnsPerPixel;
}

- (double)minimumFramesPerPointForWaveform:(AudioWaveform *)waveform {
    if ([self columnsPerPoint] > 0 && waveform->isComplete()) {
        return kVibeWaveformMinimumDetailFramesPerPoint;
    }
    // Wiggle counts its loops at rest, so a zoom only stretches them.
    return [self columnsPerPoint] > 0 || _wiggle ? VibeWaveformMinimumFramesPerPoint(waveform->binFrames())
                                                : [super minimumFramesPerPointForWaveform:waveform];
}

- (void)fillColumns:(float *)out framesPerColumn:(double)frames first:(int64_t)first count:(NSUInteger)count
           waveform:(AudioWaveform *)waveform {
    if (count == 0) {
        return;
    }
    if (_wiggle) {
        // Keeps the [min, max] layout morphs and dips share.
        [self fillLevels:out + 1 stride:2 framesPerColumn:frames first:first count:count waveform:waveform];
        for (NSUInteger i = 0; i < count; i++) out[i * 2] = 0;
        return;
    }
    // Each column keeps its own min and max, scaled so the peaks draw the
    // level around them: DC-offset asymmetry and fine texture survive. The
    // level is the loudest window of each column on a coarser grid, read
    // linearly between that grid's centers, so no edge of it shows when
    // zoomed in.
    _columns.resize(count);
    waveform->columns(frames, first, count, _columns.data());
    double total = (double)waveform->totalFrames();
    double levelFrames = fmax(frames * [self levelColumnsPerColumn], total / kVibeWaveformLevelColumns);
    double firstLevel = fmax(0, floor(((double)first + 0.5) * frames / levelFrames - 0.5));
    double endLevel = fmin(ceil(total / levelFrames),
                           floor(((double)first + count - 0.5) * frames / levelFrames - 0.5) + 2);
    size_t levelCount = endLevel > firstLevel ? (size_t)(endLevel - firstLevel) : 0;
    if (levelCount == 0) {
        std::fill(out, out + count * 2, 0.0f);
        return;
    }
    _levels.resize(levelCount);
    [self fillLevels:_levels.data() stride:1 framesPerColumn:levelFrames first:(int64_t)firstLevel count:levelCount
            waveform:waveform];
    const float *levels = _levels.data();
    const wavecore::Column *levelColumns = _fillColumns.data(), *columns = _columns.data();
    for (NSUInteger i = 0; i < count; i++) {
        wavecore::ColumnPair pair = wavecore::ColumnPairAroundFrame(((double)first + i + 0.5) * frames, levelFrames,
                                                                    (int64_t)firstLevel, levelCount);
        size_t left = pair.left, right = pair.right;
        float toRight = pair.toRight;
        float leftPeak = levelColumns[left].extent(), rightPeak = levelColumns[right].extent();
        float leftGain = leftPeak > 0 ? levels[left] / leftPeak : 0;
        float rightGain = rightPeak > 0 ? levels[right] / rightPeak : 0;
        // Silence has no shape to scale: the music beside it reaches across.
        if (leftPeak == 0) {
            leftGain = rightGain;
        } else if (rightPeak == 0) {
            rightGain = leftGain;
        }
        // TRAP: the gain is the level over its peak, and a column scales its
        // own peaks by it, capped at the louder level beside it. A column
        // holding a transient then draws the transient's level, and the quiet
        // columns beside it stay quiet. Scaled to the level directly, they
        // would be drawn up to the transient's.
        float extent = columns[i].extent();
        float gain = leftGain + (rightGain - leftGain) * toRight;
        float scale = extent > 0 ? fminf(gain, fmaxf(levels[left], levels[right]) / extent) : 0;
        out[i * 2] = columns[i].lo * scale;
        out[i * 2 + 1] = columns[i].hi * scale;
    }
}

// TRAP: the level grid is never finer than kLevelPixels. Its levels change
// from column to column, and finer than a pixel they alias into a comb that
// slides as a resize moves it. A multiple of the step's own columns, so a
// step keeps one grid at every width.
static const double kLevelPixels = 4;

- (double)levelColumnsPerColumn {
    double columnsPerPixel = [self columnsPerPoint] / _pixels.scale;
    return columnsPerPixel > 0 ? kLevelPixels * columnsPerPixel : 1;
}

- (void)backingScaleDidChange {
    [super backingScaleDidChange];
    [self setHoverHighlightX:self.hoverHighlightX];
}

// The morph's rebuild callback: the picture's coverage for the render
// window, by the style's geometry.
- (void)rebuildMask {
    const std::vector<float> &samples = [_morph displayedSamples];
    VibeRenderPixels pixels = _pixels;
    CGSize size = _morph.size;
    NSUInteger count = samples.size() / 2;
    BOOL flipped = _barMask.contentsAreFlipped;
    CGImageRef image = NULL;
    // An empty picture draws nothing: Wiggle's flattened loops have faded out.
    float opacity = count > 0 ? 1 : 0;
    VibeSignpostBegin(waveform_raster);
    if (count == 0) {
        // Nothing to draw: nothing kept at the size of the waveform last drawn.
        std::vector<float>().swap(_bottoms);
        std::vector<float>().swap(_tops);
        std::vector<wavecore::Column>().swap(_columns);
        std::vector<wavecore::Column>().swap(_fillColumns);
        std::vector<float>().swap(_levels);
        _coverage.reset();
        _picture.clear();
    }
    if (count > 0 && pixels.width() > 0 && pixels.height > 0) {
        if (_wiggle) {
            opacity = [self wiggleOpacityForSamples:samples];
            image = opacity > 0 ? [self newWiggleImageForSamples:samples pixels:pixels size:size flipped:flipped]
                                : NULL;
        } else if ([self columnsPerPoint] > 0) {
            image = [self newColumnImageForSamples:samples pixels:pixels flipped:flipped];
        } else {
            image = [self newBarImageForSamples:samples pixels:pixels size:size flipped:flipped];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _barMask.frame = pixels.frameForHeight(size.height);
    _barMask.contents = (__bridge id)image;
    _barMask.opacity = opacity;
    [CATransaction commit];
    CGImageRelease(image);
    VibeSignpostEnd(waveform_raster);
}

- (void)fillSpansForSamples:(const std::vector<float> &)samples height:(CGFloat)height scale:(CGFloat)scale {
    size_t count = samples.size() / 2;
    _bottoms.resize(count);
    _tops.resize(count);
    VibeFillSpans(_bottoms.data(), _tops.data(), samples.data(), count, height, _morph.barMinHeight * scale,
                  self.centered, _morph.isSettled);
}

// The coverage of a picture this tall, kept across rebuilds.
- (wavecore::ColumnCoverage &)coverageForHeight:(int)height {
    if (!_coverage || _coverage->height() != height) {
        _coverage = std::make_unique<wavecore::ColumnCoverage>(height);
    }
    return *_coverage;
}

// The two steps' columns, each landing in the pixels it overlaps by its
// share, the coarser weighted by how near the view is to its scale.
- (CGImageRef)newColumnImageForSamples:(const std::vector<float> &)samples pixels:(VibeRenderPixels)pixels
                               flipped:(BOOL)flipped CF_RETURNS_RETAINED {
    wavecore::StepWindow window = _window;
    if (samples.size() != window.columnCount() * 2) {
        return NULL;
    }
    [self fillSpansForSamples:samples height:pixels.height scale:pixels.scale];
    const float *bottoms = _bottoms.data(), *tops = _tops.data();
    double framesPerPixel = [self framesPerPixel];
    const double perPixel[2] = {framesPerPixel / window.parts[0].framesPerColumn(),
                                framesPerPixel / window.parts[1].framesPerColumn()};
    VibeStepPicture::Look look = {pixels.height, pixels.scale, flipped, framesPerPixel,
                                  {window.parts[0].step, window.parts[1].step}, window.coarse};
    look.style = {(float)self.centered, (float)(_morph.barMinHeight * pixels.scale), (float)_morph.isSettled};
    // The rows the spans reach, from the top.
    float lowest = 0, highest = 0;
    vDSP_minv(bottoms, 1, &lowest, _bottoms.size());
    vDSP_maxv(tops, 1, &highest, _tops.size());
    wavecore::ColumnCoverage &columns = [self coverageForHeight:pixels.height];
    // A column's coverage costs less than copying it, unless only a sliver
    // changes: a streaming load's front. Measured scrolling a window by half
    // its width, the copy cost a third more than drawing the half.
    return _picture.newImage(look, pixels, window, 2, samples, (int)floorf(pixels.height - highest),
                             (int)ceilf(pixels.height - lowest), 0.25f, self.pictureColorSpace, !_morph.isSettled,
                             [&](uint32_t *out, ptrdiff_t stride, int x0, int x1) {
        columns.draw(x0, x1, out, stride, [&](int x, auto add) {
            for (int p = 0; p < 2; p++) {
                float weight = window.weight(p);
                size_t offset = window.offset(p);
                if (weight > 0) {
                    wavecore::ForEachColumnShare(x, perPixel[p], window.parts[p].first, window.parts[p].count,
                                                 [&](size_t i, float share) {
                        add(bottoms[offset + i], tops[offset + i], weight * share);
                    });
                }
            }
        });
    });
}

// Bars at the style's pitch and width, each pixel covered by its part of them.
- (CGImageRef)newBarImageForSamples:(const std::vector<float> &)samples pixels:(VibeRenderPixels)pixels
                               size:(CGSize)size flipped:(BOOL)flipped CF_RETURNS_RETAINED {
    NSUInteger count = samples.size() / 2;
    [self fillSpansForSamples:samples height:pixels.height scale:pixels.scale];
    const float *bottoms = _bottoms.data(), *tops = _tops.data();
    double pitch = size.width * pixels.scale / count;
    double barWidth = [self barWidthForWidth:size.width barCount:count] * pixels.scale;
    wavecore::ColumnCoverage &columns = [self coverageForHeight:pixels.height];
    return VibeNewLayerImage(self.pictureColorSpace, flipped, pixels.width(), pixels.height,
                             [&](uint32_t *out, ptrdiff_t stride) {
        columns.draw(pixels.x0, pixels.x1, out, stride, [&](int x, auto add) {
            long first = MAX(0L, (long)floor((x - barWidth) / pitch));
            long end = MIN((long)count, (long)ceil((x + 1) / pitch));
            for (long i = first; i < end; i++) {
                double overlap = fmin(x + 1, i * pitch + barWidth) - fmax(x, i * pitch);
                if (overlap > 0) {
                    add(bottoms[i], tops[i], (float)overlap);
                }
            }
        });
    });
}

// Fade as the last loops flatten below their pitch; otherwise their connected
// baseline stays solid until the final snap.
- (float)wiggleOpacityForSamples:(const std::vector<float> &)samples {
    if (_morph.barMinHeight != 0) {
        return 1;
    }
    float peak = 0;
    for (size_t i = 1; i < samples.size(); i += 2) peak = MAX(peak, samples[i]);
    return MIN(1, peak * VibeWiggleVScale(_morph.size.height, self.centered, self.barWidthScale) / kWigglePitch);
}

// The centerline stroked by Core Graphics, the render window's part of it,
// into the one image factory's pixels. The rows are handed top-down, and the
// CTM flips them for a flipped layer.
- (CGImageRef)newWiggleImageForSamples:(const std::vector<float> &)samples pixels:(VibeRenderPixels)pixels
                                  size:(CGSize)size flipped:(BOOL)flipped CF_RETURNS_RETAINED {
    NSUInteger count = samples.size() / 2;
    CGColorSpaceRef space = self.pictureColorSpace;
    return VibeNewLayerImage(space, NO, pixels.width(), pixels.height, [&](uint32_t *out, ptrdiff_t stride) {
        CGContextRef ctx = CGBitmapContextCreate(out, (size_t)pixels.width(), (size_t)pixels.height, 8,
                (size_t)stride * sizeof(uint32_t), VibePictureColorSpace(space),
                (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
        if (!ctx) {
            return;
        }
        if (flipped) {
            CGContextTranslateCTM(ctx, 0, pixels.height);
            CGContextScaleCTM(ctx, 1, -1);
        }
        CGContextScaleCTM(ctx, pixels.scale, pixels.height / size.height);
        CGContextTranslateCTM(ctx, -pixels.x0 / pixels.scale, 0);
        CGPathRef path = VibeNewWigglePath(size, samples.data(), count, self.centered, self.barWidthScale,
                pixels.frameForHeight(size.height));
        CGContextAddPath(ctx, path);
        CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
        CGContextSetLineWidth(ctx, VibeWiggleStrokeForSize(size, count, self.barWidthScale));
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextStrokePath(ctx);
        CGPathRelease(path);
        CGContextRelease(ctx);
    });
}

@end
