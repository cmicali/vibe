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

// Bars reach at most ±kBarAmplitudeOfHalfHeight times half the height from the vertical
// midline. VibeBarVScale is the one normalized-to-pixels scale, shared by the
// seek hit band in seekHitBandForBounds:, the morph engine's frame-skip
// heuristic through the vscale block handed to it in init, the drawn mask in
// rebuildMaskPaths and the gradient band in configureGradient:. They disagree
// silently if any site re-derives it.
static const CGFloat kBarAmplitudeOfHalfHeight = 0.75;
static inline CGFloat VibeBarVScale(CGFloat height) {
    return (height / 2) * kBarAmplitudeOfHalfHeight;
}

// The width of the hover highlight column. A single bar is sub-point wide at
// these bar counts, 1,024 and up, so the highlight spans a few of them: wide
// enough to read as a lit slice of the waveform, narrow enough to stay a line
// rather than a blob. It is rounded to whole device pixels at use; see
// setHoverHighlightX:. A fractional width leaves a half-lit edge pixel, so the
// column never actually reaches full brightness.
static const CGFloat kHoverHighlightWidth = 1.5;

static const CGFloat kWiggleStrokeWidth = 1.5;
static const CGFloat kWigglePitch = 8;
static const NSUInteger kWiggleMaxLoops = 1024;

static CGFloat VibeWiggleStrokeForSize(CGSize size, NSUInteger count, CGFloat widthScale) {
    return MIN(kWiggleStrokeWidth, size.width / (MAX((NSUInteger)1, count) * 4)) * widthScale;
}

static CGFloat VibeWiggleVScale(CGFloat height, BOOL centered, CGFloat widthScale) {
    return MAX(0, VibeBarVScale(height) * 2 - kWiggleStrokeWidth * widthScale) / (centered ? 2 : 1);
}

// Keep the centerline: expanding every curve into a filled outline makes
// resizing and morph frames pay for a second, much larger path.
static CGPathRef VibeNewWigglePath(CGSize size, const float *samples, NSUInteger count,
                                  BOOL centered, CGFloat widthScale) CF_RETURNS_RETAINED;
static CGPathRef VibeNewWigglePath(CGSize size, const float *samples, NSUInteger count,
                                  BOOL centered, CGFloat widthScale) {
    CGMutablePathRef line = CGPathCreateMutable();
    CGFloat stroke = VibeWiggleStrokeForSize(size, count, widthScale);
    CGFloat amplitude = VibeWiggleVScale(size.height, centered, widthScale);
    if (count == 0 || size.width <= stroke || amplitude == 0) return line;
    CGFloat baseline = centered ? size.height / 2
            : size.height / 2 - VibeBarVScale(size.height) + stroke / 2;
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

// This family's resting levels live in the theme colors' own alpha
// (WaveformTheme.h) — the White pair carries what used to be this file's
// kWaveformOpacity — so the renderer owns only the ramp SHAPE below, scaled
// relative to each color's level through VibeColorWithScaledAlpha. The
// envelope bitmap bakes the same stops, so the two cannot drift.

@implementation DetailedAudioWaveformRenderer {
    BOOL _wiggle;
    BOOL _wiggleCentered;
    // One bar-shaped mask clips the whole gradient stack. Masking the two
    // gradients separately would rasterize the identical bar path twice per
    // morph frame, a full-view alpha pass each, and ship the 4,096-element
    // path to the render server twice.
    CALayer *_waveformContainer;      // mask: _barMask; holds both gradients
    CAShapeLayer *_barMask;
    CAGradientLayer *_unplayedGradient;

    // A container layer with masksToBounds=YES. Its bounds.size.width is the
    // progress indicator, so anything inside is clipped to the played region.
    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;

    // The hover highlight: a flat, full-brightness column. It is a sibling
    // inside _waveformContainer, so the shared bar mask clips it to the
    // waveform's own envelope, which makes the lit slice the waveform rather
    // than a line drawn over it.
    CALayer *_hoverColumn;

    // rebuildMaskPaths' rect scratch, kept across the 60 Hz morph so the bars
    // reach the path through one CGPathAddRects call: appending 4,096 rects
    // one at a time regrew the path's buffer on the way, and that regrowth was
    // 40% of the rebuild.
    std::vector<CGRect> _barRects;
}

+ (NSString *)styleIdentifier {
    return @"detailed";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_DETAILED;
}

// 1,024 bars across the 512pt design-width waveform: a designed pitch of half
// a point, and the count follows the width at that pitch, so a resize adds or
// removes bars rather than stretching them. The cap bounds the mask path
// against pathological widths — the iOS scrubber's zoomed virtual width
// included — and sits at data resolution: the cached waveform holds 8,192
// chunks, so bars beyond that only repeat values.
static const CGFloat kDetailedBarPitch = 0.5;
static const NSUInteger kDetailedMaxBars = 8192;

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    if (_wiggle && self.samplingWidth > 0) width = self.samplingWidth;
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) * (_wiggle ? self.barDensity : 1)
                                           / (_wiggle ? kWigglePitch : kDetailedBarPitch));
    return clampRange(count, (NSUInteger)2, _wiggle ? kWiggleMaxLoops : kDetailedMaxBars);
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return width / (CGFloat)count;
}

// Matches the drawn band: bars reach at most ±kBarAmplitudeOfHalfHeight times half the
// height from the midline, through VibeBarVScale.
- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    CGFloat midY = bounds.size.height / 2;
    CGFloat vscale = VibeBarVScale(bounds.size.height);
    CGFloat bottomY = round(midY - vscale);
    CGFloat topY = round(midY + vscale);
    return CGRectMake(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    return [self initWithLayer:parentLayer bounds:bounds isDark:isDark wiggle:NO centered:NO];
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                       wiggle:(BOOL)wiggle centered:(BOOL)centered {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        NSAssert(!wiggle || self.class == DetailedAudioWaveformRenderer.class,
                 @"Wiggle variants require DetailedAudioWaveformRenderer's geometry hooks");
        _wiggle = wiggle;
        _wiggleCentered = centered;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) {
                    return wiggle ? VibeWiggleVScale(height, centered, weakSelf.barWidthScale) : VibeBarVScale(height);
                }
                       rebuild:^{ [weakSelf rebuildMaskPaths]; }];
        _morph.samplesPerBar = 2; // interleaved [min, max] per bar
        [self setupGradientLayers];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)setupGradientLayers {
    CGFloat scale = self.parentLayer.contentsScale;

    // Everything composites inside one container that the bar mask clips: the
    // unplayed gradient across the full width, and the played gradient above
    // it, revealed by the progress clip. Mask path updates always happen
    // inside setDisableActions:YES transactions, because every visible morph
    // is the timer-driven rebuild in rebuildMaskPaths, never a Core Animation
    // path interpolation.
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

    // Unplayed: a dim gradient over the full waveform.
    _unplayedGradient = [CAGradientLayer layer];
    _unplayedGradient.contentsScale = scale;
    [self configureGradient:_unplayedGradient];
    [_waveformContainer addSublayer:_unplayedGradient];

    // Played: a bright gradient inside a clip container. Resizing the
    // container on a progress change reveals or hides the played portion. It
    // sits on top of the unplayed gradient, so its brighter colors win
    // wherever it is visible.
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

    // Added last, so that it composites over both gradients, and at full
    // opacity — this column is meant to be the brightest thing in the
    // waveform, which the theme's hover derivation guarantees.
    _hoverColumn = [CALayer layer];
    _hoverColumn.anchorPoint = CGPointZero;
    _hoverColumn.actions = @{@"bounds": [NSNull null], @"position": [NSNull null],
                             @"hidden": [NSNull null], @"backgroundColor": [NSNull null]};
    _hoverColumn.contentsScale = scale;
    _hoverColumn.hidden = YES;
    [_waveformContainer addSublayer:_hoverColumn];
}

- (void)configureGradient:(CAGradientLayer *)gradient {
    // The fade runs from top to bottom. In layer coordinates y=1 is the top
    // and y=0 the bottom, so colors[0] is the top color and the last entry is
    // the bottom. The start and end points are pinned to the waveform's
    // vertical band rather than the full view, so that the whole 100%-to-70%
    // range lands across the visible bars. Bars reach at most ±kBarAmplitudeOfHalfHeight
    // times half the height from the midline, through VibeBarVScale, so the
    // band spans y in [(1∓kBarAmplitudeOfHalfHeight)/2]. It is computed, so an amplitude
    // change re-aims the fade automatically. Mapping the fade to the whole
    // view instead would swing the bars only from about 0.96 to 0.74, too
    // subtle to read.
    gradient.startPoint = CGPointMake(0.5, (1 + kBarAmplitudeOfHalfHeight) / 2);
    gradient.endPoint = CGPointMake(0.5, (1 - kBarAmplitudeOfHalfHeight) / 2);
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
    // Full alpha and no vertical fade. The played gradient's own top is the
    // ceiling everywhere else, so this reads as lit at every bar height.
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
}

// A slight vertical fade: the color at its own resting alpha at the top,
// kBottomAlpha of it at the bottom. One shape serves both sides — the
// played/unplayed difference is entirely the theme colors' levels, which is
// why the played region reads brighter where the two meet at the boundary.
// The stops are the same in light and dark, because the gradient's startPoint
// and endPoint fix the direction, not the array order.
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark {
    if (self.theme.flatFill) {
        return @[color, color];
    }
    const CGFloat kBottomAlpha = 0.45;
    return @[
            color,
            VibeColorWithScaledAlpha(color, kBottomAlpha),
    ];
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

// The polymorphic hook — Basic overrides this with its block-quantized
// column; the snap itself is the shared rule (VibeSnappedColumnRect).
- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale {
    if (_wiggle) {
        NSUInteger count = [self numBarsForWidth:bounds.size.width];
        CGFloat stroke = VibeWiggleStrokeForSize(bounds.size, count, self.barWidthScale);
        CGFloat width = MAX(0, bounds.size.width - stroke);
        NSUInteger index = (NSUInteger)VibeBlockIndexForX(x - stroke / 2,
                                                          width, (NSInteger)count);
        CGFloat pitch = width / count;
        // Include the stroke at both valleys, then expand to whole pixels.
        CGFloat left = floor(index * pitch * scale) / scale;
        CGFloat right = ceil(((index + 1) * pitch + stroke) * scale) / scale;
        return CGRectMake(left, 0, right - left, bounds.size.height);
    }
    return VibeSnappedColumnRect(x, kHoverHighlightWidth,
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
    // Actions are disabled here. An animated window resize redraws every
    // frame, and implicit 0.25s animations on these leave the waveform chasing
    // the window. _playedClip needs no wrapper, because its actions dictionary
    // already disables bounds and position.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _waveformContainer.frame = localBounds;
    _barMask.frame = localBounds;
    _unplayedGradient.frame = localBounds;
    _playedGradient.frame = localBounds;
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];
    // A resize changes the column's height, and its clamp, so re-place it.
    [self setHoverHighlightX:self.hoverHighlightX];

    // The x2, x4 and x8 styles intentionally draw more rects than there are
    // device pixels. The sub-pixel overlap accumulates differently at each
    // density, and that is what visually distinguishes the oversampling
    // variants. Do not clamp to the pixel count.
    NSUInteger count = [self numBarsForWidth:bounds.size.width];

    // The target the bars ease toward: the waveform's per-bar energy-scaled
    // envelope, or all-zero, collapsed to the midline, when there is no waveform. A track
    // change therefore morphs the old bars toward zero until the new track's
    // waveform arrives and retargets them to its shape. The engine owns the
    // fast, collapsed and commit scaffold and skips this fill on a live-resize
    // frame, where the waveform identity and count are unchanged. Only the
    // sampling itself belongs to this family.
    [_morph updateTargetForSize:bounds.size identity:waveform count:count * 2
                           fill:^(std::vector<float> &target) {
        [self fillEnvelope:target.data() barCount:count waveform:waveform];
    }];
}

- (void)fillEnvelope:(float *)out barCount:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    if (_wiggle) {
        // Preserve the shared [min, max] layout for morphs, dips and bakes.
        [self fillEnergyLevels:out + 1 count:count stride:2 waveform:waveform];
        for (NSUInteger i = 0; i < count; i++) out[i * 2] = 0;
        return;
    }
    // Scale each bar by its energy column's peak extent to preserve DC-offset
    // asymmetry and fine texture. Cache columns across oversampled bars.
    NSUInteger lastColumnIndex = NSNotFound;
    float columnExtent = 0, columnLevel = 0;
    float fullScaleRMS = VibeWaveformFullScaleRMSForWaveform(waveform, self.normalizesLevels, count);
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        NSUInteger columnIndex = VibeWaveformEnergyColumnIndexForBar(i, count);
        if (lastColumnIndex != columnIndex) {
            AudioWaveformCacheChunk c = count > kVibeWaveformEnergyColumns
                    ? VibeWaveformEnergyColumnForBar(waveform, i, count) : m;
            lastColumnIndex = columnIndex;
            columnExtent = fmaxf(fabsf(c.getMin()), fabsf(c.getMax()));
            columnLevel = VibeWaveformBarLevel(c.getMeanSquare(), fullScaleRMS, gainDB);
        }
        // A bar straddling two columns may carry a peak its mapped column
        // lacks; the wider extent keeps it on the envelope rather than past it.
        float extent = fmaxf(columnExtent, fmaxf(fabsf(m.getMin()), fabsf(m.getMax())));
        float scale = extent > 0 ? columnLevel / extent : 0;
        out[i * 2] = m.getMin() * scale;
        out[i * 2 + 1] = m.getMax() * scale;
    }
}

- (void)backingScaleDidChange {
    [super backingScaleDidChange];
    // Re-snap the hover column to the new device-pixel grid.
    [self setHoverHighlightX:self.hoverHighlightX];
}

// The live mask reuses its scratch; bitmap workers supply their own. A zero
// scale keeps morph frames between pixels instead of rounding their motion.
- (void)fillBarRects:(std::vector<CGRect> &)rects size:(CGSize)size samples:(const float *)samples
      minimumHeight:(CGFloat)minimumHeight scale:(CGFloat)scale {
    NSUInteger count = rects.size();
    CGFloat midY = size.height / 2;
    CGFloat vscale = VibeBarVScale(size.height);
    CGFloat barWidth = [self barWidthForWidth:size.width barCount:count];
    CGFloat barPitch = size.width / (CGFloat)count;
    for (NSUInteger i = 0; i < count; i++) {
        // y-up: adding the negative min preserves DC-offset asymmetry.
        CGFloat top = midY + samples[i * 2 + 1] * vscale;
        CGFloat bottom = midY + samples[i * 2] * vscale;
        if (scale > 0) {
            top = round(top * scale) / scale;
            bottom = round(bottom * scale) / scale;
        }
        CGFloat x = barPitch * (CGFloat)i;
        rects[i] = CGRectMake(x, bottom, barWidth, MAX(top - bottom, minimumHeight));
    }
}

// Builds the bar path for the currently displayed samples and sets it on the
// shared mask. It is the morph engine's rebuild callback. Pixel-rounding is
// reserved for the settled state, because mid-morph it would quantize the
// motion into visible one-pixel steps.
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
            opacity = MIN(1, peak * VibeWiggleVScale(_morph.size.height, _wiggleCentered, self.barWidthScale) / kWigglePitch);
        }
        path = opacity > 0 ? VibeNewWigglePath(_morph.size, samples.data(), count, _wiggleCentered, self.barWidthScale)
                           : CGPathCreateMutable();
    } else {
        _barRects.resize(count);
        [self fillBarRects:_barRects size:_morph.size samples:samples.data()
            minimumHeight:_morph.barMinHeight
                    scale:_morph.isSettled ? VibeBackingScaleForLayer(self.parentLayer) : 0];
        CGMutablePathRef bars = CGPathCreateMutable();
        CGPathAddRects(bars, NULL, _barRects.data(), count);
        path = bars;
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
    // The live tree's count for the host's current width — parentLayer is the
    // scrubber's virtual-size host — so the bake stays pixel-identical to the
    // layers it replaces.
    NSUInteger count = [self numBarsForWidth:self.parentLayer.bounds.size.width];
    NSMutableData *data = [NSMutableData dataWithLength:count * 2 * sizeof(float)];
    [self fillEnvelope:(float *)data.mutableBytes barCount:count waveform:waveform];
    return data;
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientCGColorsForColor:self.theme.playedColor]];
}

- (CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientCGColorsForColor:self.theme.unplayedColor]];
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples
                                stops:(NSArray *)stops {
    NSUInteger count = samples.length / (2 * sizeof(float));
    size_t pixelWidth = (size_t)llround(size.width * scale);
    size_t pixelHeight = (size_t)llround(size.height * scale);
    if (count == 0 || pixelWidth == 0 || pixelHeight == 0) {
        return NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelWidth, pixelHeight, 8, 0, space,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    if (!ctx) {
        CGColorSpaceRelease(space);
        return NULL;
    }
    CGContextScaleCTM(ctx, scale, scale);

    if (_wiggle) {
        CGPathRef path = VibeNewWigglePath(size, (const float *)samples.bytes, count, _wiggleCentered, self.barWidthScale);
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
        [self fillBarRects:rects size:size samples:(const float *)samples.bytes minimumHeight:1 scale:scale];
        CGContextAddRects(ctx, rects.data(), count);
        CGContextClip(ctx);
    }

    // configureGradient:'s band-pinned fade. This family's fade only — Basic
    // re-aims its gradient, so its styles would need their own bake. The
    // stops are the caller's theme-derived ramp, resting levels already in
    // their alphas, same as the live layers': the two must stay
    // pixel-identical.
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)stops, NULL);
    CGFloat topY = size.height * (1 + kBarAmplitudeOfHalfHeight) / 2;
    CGFloat bottomY = size.height * (1 - kBarAmplitudeOfHalfHeight) / 2;
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, topY), CGPointMake(0, bottomY),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
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
