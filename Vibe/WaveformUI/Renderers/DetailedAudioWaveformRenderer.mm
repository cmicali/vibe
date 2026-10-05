//
//  DetailedAudioWaveformRenderer.mm
//  Vibe
//

#import "DetailedAudioWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "PlatformTypes.h"
#import "PlatformColor.h"
#import "VibeStrings.h"

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
                                  BOOL centered, CGFloat widthScale) CF_RETURNS_RETAINED;
static CGPathRef VibeNewWigglePath(CGSize size, const float *samples, NSUInteger count,
                                  BOOL centered, CGFloat widthScale) {
    CGMutablePathRef line = CGPathCreateMutable();
    CGFloat stroke = VibeWiggleStrokeForSize(size, count, widthScale);
    CGFloat amplitude = VibeWiggleVScale(size.height, centered, widthScale);
    if (count == 0 || size.width <= stroke || amplitude == 0) return line;
    CGFloat baseline = centered ? size.height / 2 : VibeBarBaseline(size.height) + stroke / 2;
    CGFloat pitch = (size.width - stroke) / count;
    CGFloat radiusX = pitch / 4;
    const CGFloat kCircleControl = 0.5522847498;
    CGFloat bottom = baseline;
    CGPathMoveToPoint(line, NULL, stroke / 2, bottom);
    for (NSUInteger i = 0; i < count; i++) {
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

// The bars' mask. Bars that abut, as Detailed's do at a width of their pitch,
// are one outline along their tops and back along their bottoms, with a step
// only where the level changes: under the nonzero rule it covers what their
// rects cover, in at most four path elements a bar where a rect apiece is
// five, and appending those was nine tenths of a rebuild. Pixel-rounded bars
// fill byte for byte as their rects do; a morph frame's unrounded ones
// antialias a few levels apart, neither nearer the exact area. Bars with gaps
// (Basic's) stay rects. points is the caller's scratch.
static CGPathRef VibeNewBarMaskPath(const CGRect *rects, NSUInteger count,
                                    std::vector<CGPoint> &points) CF_RETURNS_RETAINED;
static CGPathRef VibeNewBarMaskPath(const CGRect *rects, NSUInteger count, std::vector<CGPoint> &points) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (count < 2 || rects[0].size.width < rects[1].origin.x - rects[0].origin.x) {
        CGPathAddRects(path, NULL, rects, count);
        return path;
    }
    points.resize(4 * count);
    CGPoint *point = points.data();
    CGFloat left = rects[0].origin.x, right = CGRectGetMaxX(rects[count - 1]);
    CGFloat level = rects[0].origin.y + rects[0].size.height;
    *point++ = CGPointMake(left, level);
    for (NSUInteger i = 1; i < count; i++) {
        CGFloat next = rects[i].origin.y + rects[i].size.height;
        if (next != level) {
            *point++ = CGPointMake(rects[i].origin.x, level);
            *point++ = CGPointMake(rects[i].origin.x, next);
            level = next;
        }
    }
    *point++ = CGPointMake(right, level);
    level = rects[count - 1].origin.y;
    *point++ = CGPointMake(right, level);
    for (NSUInteger i = count - 1; i > 0; i--) {
        CGFloat next = rects[i - 1].origin.y;
        if (next != level) {
            *point++ = CGPointMake(rects[i].origin.x, level);
            *point++ = CGPointMake(rects[i].origin.x, next);
            level = next;
        }
    }
    *point++ = CGPointMake(left, level);
    CGPathAddLines(path, NULL, points.data(), (size_t)(point - points.data()));
    CGPathCloseSubpath(path);
    return path;
}

// Templated on the two per-call choices so the per-bar loop, a tenth of a
// resize frame, carries no branch. y-up: adding the negative min preserves
// DC-offset asymmetry; grounded, the bar keeps its height on the baseline.
template <bool Centered, bool Snap>
static void VibeFillBars(CGRect *rects, NSUInteger count, const float *samples, CGSize size, CGFloat scale,
                         CGFloat barWidth, CGFloat minimumHeight) {
    CGFloat midY = size.height / 2, baseline = VibeBarBaseline(size.height), vscale = VibeBarVScale(size.height);
    CGFloat barPitch = size.width / (CGFloat)count;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat top = Centered ? midY + samples[i * 2 + 1] * vscale
                               : baseline + (samples[i * 2 + 1] - samples[i * 2]) * vscale;
        CGFloat bottom = Centered ? midY + samples[i * 2] * vscale : baseline;
        if (Snap) {
            top = round(top * scale) / scale;
            bottom = round(bottom * scale) / scale;
        }
        rects[i] = CGRectMake(barPitch * (CGFloat)i, bottom, barWidth, MAX(top - bottom, minimumHeight));
    }
}

@implementation DetailedAudioWaveformRenderer {
    BOOL _wiggle;
    // One mask for the whole stack: masking each gradient would rasterize and
    // ship the same bar path twice per morph frame.
    CALayer *_waveformContainer;      // mask: _barMask; holds both gradients
    CAShapeLayer *_barMask;
    CAGradientLayer *_unplayedGradient;

    // masksToBounds; its width is the playhead.
    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;

    // Inside _waveformContainer, so the bar mask clips it to the envelope: the
    // lit slice is the waveform, not a line over it.
    CALayer *_hoverColumn;

    // Kept across morph frames, so a rebuild allocates neither.
    std::vector<CGRect> _barRects;
    std::vector<CGPoint> _maskPoints;
}

+ (NSString *)styleIdentifier {
    return @"detailed";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_DETAILED;
}

// The cap (kVibeWaveformMaxBars) bounds the mask path against the scrubber's
// zoomed virtual width.
static const CGFloat kDetailedBarPitch = 0.5;

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    if (_wiggle && self.samplingWidth > 0) width = self.samplingWidth;
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) * (_wiggle ? self.barDensity : 1)
                                           / (_wiggle ? kWigglePitch : kDetailedBarPitch));
    return clampRange(count, (NSUInteger)2, _wiggle ? kWiggleMaxLoops : kVibeWaveformMaxBars);
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
        NSAssert(!wiggle || self.class == DetailedAudioWaveformRenderer.class,
                 @"Wiggle variants require DetailedAudioWaveformRenderer's geometry hooks");
        _wiggle = wiggle;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) {
                    return wiggle ? VibeWiggleVScale(height, weakSelf.centered, weakSelf.barWidthScale)
                                  : VibeBarVScale(height);
                }
                       rebuild:^{ [weakSelf rebuildMaskPaths]; }];
        _morph.samplesPerBar = 2;
        [self setupGradientLayers];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)setupGradientLayers {
    CGFloat scale = self.parentLayer.contentsScale;

    // Mask path updates always run with actions disabled: every morph is the
    // timer-driven rebuild, never a Core Animation path interpolation.
    _waveformContainer = [CALayer layer];
    _waveformContainer.anchorPoint = CGPointZero;
    _waveformContainer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
    _waveformContainer.contentsScale = scale;
    _barMask = [CAShapeLayer layer];
    _barMask.fillColor = _wiggle ? nil : [VibeColor whiteColor].CGColor;
    if (_wiggle) {
        _barMask.strokeColor = [VibeColor whiteColor].CGColor;
        _barMask.lineCap = kCALineCapRound;
        _barMask.lineJoin = kCALineJoinRound;
    }
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
    if (x < 0 || b.size.width <= 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _hoverColumn.hidden = YES;
        [CATransaction commit];
        return;
    }
    CGRect column = [self hoverColumnRectForX:x bounds:b
                                        scale:VibeBackingScaleForLayer(self.parentLayer)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _hoverColumn.bounds = CGRectMake(0, 0, column.size.width, column.size.height);
    _hoverColumn.position = column.origin;
    _hoverColumn.hidden = NO;
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
    _barMask.frame = localBounds;
    _unplayedGradient.frame = localBounds;
    _playedGradient.frame = localBounds;
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];
    [self setHoverHighlightX:self.hoverHighlightX];

    // The oversampling styles draw more bars than device pixels on purpose:
    // the sub-pixel overlap IS their look. Do not clamp to the pixel count.
    NSUInteger count = [self numBarsForWidth:bounds.size.width];

    [_morph updateTargetForSize:bounds.size identity:waveform count:count * 2
                           fill:^(std::vector<float> &target) {
        [self fillEnvelope:target.data() barCount:count waveform:waveform];
    }];
}

- (void)fillEnvelope:(float *)out barCount:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    if (_wiggle) {
        // Keeps the [min, max] layout morphs, dips and bakes share.
        [self fillEnergyLevels:out + 1 count:count stride:2 waveform:waveform];
        for (NSUInteger i = 0; i < count; i++) out[i * 2] = 0;
        return;
    }
    // Each bar keeps its own min and max, scaled so its energy column's peak
    // draws the column's level: DC-offset asymmetry and fine texture survive.
    // TRAP: the peak is the column's own, widened by the bar's alone. Past
    // 1,024 bars a column's bars need not cover its chunks, so their peaks
    // can miss a transient its energy holds, and quiet bars beside it would
    // be scaled up to the transient's level; widened by a neighbour's, a bar
    // straddling into the next column's transient would dip every bar
    // beside it.
    std::vector<float> levels = [self energyColumnLevelsForBarCount:count waveform:waveform];
    NSUInteger columns = levels.size(), lastColumn = NSNotFound;
    float columnExtent = 0;
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        NSUInteger column = VibeWaveformEnergyColumnIndexForBar(i, count);
        if (column != lastColumn) {
            AudioWaveformCacheChunk c = count > columns ? waveform->getChunkAtIndex(column, columns) : m;
            columnExtent = fmaxf(fabsf(c.getMin()), fabsf(c.getMax()));
            lastColumn = column;
        }
        float extent = fmaxf(columnExtent, fmaxf(fabsf(m.getMin()), fabsf(m.getMax())));
        float scale = extent > 0 ? levels[column] / extent : 0;
        out[i * 2] = m.getMin() * scale;
        out[i * 2 + 1] = m.getMax() * scale;
    }
}

- (void)backingScaleDidChange {
    [super backingScaleDidChange];
    [self setHoverHighlightX:self.hoverHighlightX];
}

// The live mask reuses its scratch; bitmap workers supply their own. A zero
// scale keeps morph frames between pixels instead of rounding their motion.
- (void)fillBarRects:(std::vector<CGRect> &)rects size:(CGSize)size samples:(const float *)samples
      minimumHeight:(CGFloat)minimumHeight scale:(CGFloat)scale {
    CGRect *bars = rects.data();
    NSUInteger count = rects.size();
    CGFloat barWidth = [self barWidthForWidth:size.width barCount:count];
    BOOL centered = self.centered;
    if (centered && scale > 0) VibeFillBars<true, true>(bars, count, samples, size, scale, barWidth, minimumHeight);
    else if (centered) VibeFillBars<true, false>(bars, count, samples, size, scale, barWidth, minimumHeight);
    else if (scale > 0) VibeFillBars<false, true>(bars, count, samples, size, scale, barWidth, minimumHeight);
    else VibeFillBars<false, false>(bars, count, samples, size, scale, barWidth, minimumHeight);
}

// The morph's rebuild callback. Pixel-rounds only when settled: mid-morph it
// would quantize the motion into visible steps.
- (void)rebuildMaskPaths {
    const std::vector<float> &samples = [_morph displayedSamples];
    NSUInteger count = samples.size() / 2;
    if (count == 0) {
        return;
    }
    VibeSignpostBegin(waveform_path);
    CGPathRef path;
    float opacity = 1;
    if (_wiggle) {
        if (_morph.barMinHeight == 0) {
            float peak = 0;
            for (NSUInteger i = 0; i < count; i++) peak = MAX(peak, samples[i * 2 + 1]);
            // Fade as the last loops flatten below their pitch; otherwise
            // their connected baseline stays solid until the final snap.
            opacity = MIN(1, peak * VibeWiggleVScale(_morph.size.height, self.centered, self.barWidthScale) / kWigglePitch);
        }
        path = opacity > 0 ? VibeNewWigglePath(_morph.size, samples.data(), count, self.centered, self.barWidthScale)
                           : CGPathCreateMutable();
    } else {
        _barRects.resize(count);
        [self fillBarRects:_barRects size:_morph.size samples:samples.data()
            minimumHeight:_morph.barMinHeight
                    scale:_morph.isSettled ? VibeBackingScaleForLayer(self.parentLayer) : 0];
        path = VibeNewBarMaskPath(_barRects.data(), count, _maskPoints);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_wiggle) _barMask.lineWidth = VibeWiggleStrokeForSize(_morph.size, count, self.barWidthScale);
    _barMask.path = path;
    _barMask.opacity = opacity;
    [CATransaction commit];
    CGPathRelease(path);
    VibeSignpostEnd(waveform_path);
}

#pragma mark - Envelope bitmap

- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform {
    // The live count for the host's width (the scrubber's virtual-size host),
    // so the bake matches the layers it replaces.
    NSUInteger count = [self numBarsForWidth:self.parentLayer.bounds.size.width];
    NSMutableData *data = [NSMutableData dataWithLength:count * 2 * sizeof(float)];
    [self fillEnvelope:(float *)data.mutableBytes barCount:count waveform:waveform];
    return data;
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientCGColorsForColor:self.theme.playedColor]];
}

// One hue: the played bitmap dimmed. Two: the unplayed side's own bake, at
// its resting alphas, doubling the cell's bytes past WaveformZoomMath's
// budget — a deliberate trade.
- (CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    if (self.theme.unplayedSharesPlayedHue) {
        return NULL;
    }
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientCGColorsForColor:self.theme.unplayedColor]];
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples
                                stops:(NSArray *)stops {
    NSUInteger count = samples.length / (2 * sizeof(float));
    CGContextRef ctx = count ? VibeNewEnvelopeBitmapContext(size, scale) : NULL;
    if (!ctx) {
        return NULL;
    }

    if (_wiggle) {
        CGPathRef path = VibeNewWigglePath(size, (const float *)samples.bytes, count, self.centered, self.barWidthScale);
        CGContextAddPath(ctx, path);
        CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
        CGContextSetLineWidth(ctx, VibeWiggleStrokeForSize(size, count, self.barWidthScale));
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextStrokePath(ctx);
        CGPathRelease(path);
        // The gradient colors the stroke's coverage, including antialiasing.
        CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
    } else {
        std::vector<CGRect> rects(count);
        std::vector<CGPoint> points;
        [self fillBarRects:rects size:size samples:(const float *)samples.bytes minimumHeight:1 scale:scale];
        CGPathRef mask = VibeNewBarMaskPath(rects.data(), count, points);
        CGContextAddPath(ctx, mask);
        CGContextClip(ctx);
        CGPathRelease(mask);
    }

    // The live layers' stops over configureGradient:'s band. Basic re-aims its
    // gradient, so it cannot bake.
    VibeFillBarGradient(ctx, size, stops, self.centered);

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

// Valid because both sides share the ramp shape, so the whole difference is
// the theme colors' resting alphas.
- (CGFloat)unplayedOverPlayedOpacity {
    CGFloat playedTop = CGColorGetAlpha(self.theme.playedColor.CGColor);
    return playedTop > 0 ? CGColorGetAlpha(self.theme.unplayedColor.CGColor) / playedTop : 1;
}

- (BOOL)supportsEnvelopeBake {
    return YES;
}

@end
