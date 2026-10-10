//
//  ThreeBandWaveformRenderer.mm
//  Vibe
//

#import "ThreeBandWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "VibeStrings.h"

#include <vector>
#include <cmath>

// Each band's full height as a share of the broadband reference: dance
// masters' measured balance, the mids and highs well under the lows, with the
// outer edge at Detailed's height (Renderers/AGENTS.md has the measurements).
static const float kBandShareOfFullScale[kAudioWaveformBandCount] = {1.0f, 0.48f, 0.48f};

// The unplayed side's level against the played.
static const float kUnplayedOpacity = 0.5f;

// Painter's order — singles, pairs, all three — so at every height the layer
// on top is the set of bands reaching it. Bit 0 is low, 1 mid, 2 high.
static const NSUInteger kLayerCount = 7;
static const NSUInteger kLayerForBands[8] = {0, 0, 1, 3, 2, 4, 5, 6};

// One bar's three bands as half-heights in points; answers the tallest.
// Silence keeps every bar style's hairline, in the all-bands color its tie
// gives it.
static CGFloat VibeThreeBandHalves(const float *bar, CGFloat vscale, CGFloat minimumHeight, CGFloat *half) {
    CGFloat tallest = 0;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        half[b] = clampRange((CGFloat)bar[b], 0, 1) * vscale;
        tallest = MAX(tallest, half[b]);
    }
    if (tallest * 2 < minimumHeight) {
        tallest = minimumHeight / 2;
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) half[b] = tallest;
    }
    return tallest;
}

// Each layer one mirrored polygon through the bars' centers, out to the
// lowest band of its set, appended to the caller's paths. The outline is the
// tallest band, built when one is given. The hover slice is masked to it, and
// Spectrum passes no paths and fills it alone. The envelopes nest as
// their sets do, since a set's lowest band is never above a subset's, so the
// painter's order alone colors each height by the bands reaching it, and the
// fill's antialiasing smooths the steps between bars. Grounded, each stands on
// the baseline at its whole height, and they nest the same way. The live
// layers and the bake both draw from here, which keeps them pixel-identical;
// points is the caller's scratch.
static void VibeAddThreeBandPaths(CGMutablePathRef *paths, CGMutablePathRef outline, std::vector<CGPoint> *points,
                                  CGSize size, const float *samples, NSUInteger count, CGFloat minimumHeight,
                                  BOOL centered) {
    if (count == 0) {
        return;
    }
    CGFloat midY = size.height / 2;
    CGFloat vscale = VibeBarVScale(size.height);
    CGFloat baseline = VibeBarBaseline(size.height);
    CGFloat pitch = size.width / (CGFloat)count;
    // Per band set (by mask; 0 is the outline), one polygon: the left edge,
    // the top through the bars' centers, the right edge, the bottom back.
    NSUInteger first = outline ? 0 : 1, end = paths ? 8 : 1;
    NSUInteger stride = 2 * count + 4;
    points->resize(end * stride);
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat half[kAudioWaveformBandCount];
        CGFloat tallest = VibeThreeBandHalves(samples + i * kAudioWaveformBandCount, vscale, minimumHeight, half);
        CGFloat x = pitch * ((CGFloat)i + 0.5);
        CGFloat lowMid = MIN(half[0], half[1]);
        const CGFloat heights[8] = {tallest, half[0], half[1], lowMid, half[2], MIN(half[0], half[2]),
                                    MIN(half[1], half[2]), MIN(lowMid, half[2])};
        for (NSUInteger mask = first; mask < end; mask++) {
            CGPoint *polygon = points->data() + mask * stride;
            CGFloat bottom = centered ? midY - heights[mask] : baseline;
            polygon[1 + i] = CGPointMake(x, bottom + 2 * heights[mask]);
            polygon[stride - 2 - i] = CGPointMake(x, bottom);
        }
    }
    for (NSUInteger mask = first; mask < end; mask++) {
        CGMutablePathRef path = mask ? paths[kLayerForBands[mask]] : outline;
        CGPoint *polygon = points->data() + mask * stride;
        polygon[0] = CGPointMake(0, polygon[1].y);
        polygon[count + 1] = CGPointMake(size.width, polygon[count].y);
        polygon[count + 2] = CGPointMake(size.width, polygon[count + 3].y);
        polygon[stride - 1] = CGPointMake(0, polygon[stride - 2].y);
        CGPathAddLines(path, NULL, polygon, stride);
        CGPathCloseSubpath(path);
    }
}

// spectrumColors as sRGB components, for VibeSpectrumColor.
static void VibeSpectrumPrimaries(NSArray<VibeColor *> *colors, float primaries[3][3]) {
    for (NSUInteger band = 0; band < kAudioWaveformBandCount; band++) {
        CGFloat rgb[3] = {};
        VibeColorGetSRGB(colors[band], &rgb[0], &rgb[1], &rgb[2]);
        for (NSUInteger c = 0; c < 3; c++) {
            primaries[band][c] = (float)rgb[c];
        }
    }
}

// Spectrum's fill: one pixel per backing pixel across the width. Each pixel
// blends the colors of the two bars whose centers it lies between. The live
// layer and the bake both draw it at its own width, and the two match. It is
// one row tall, because a bar's color does not vary with height. barColors is
// the caller's scratch.
static CGImageRef VibeNewSpectrumStrip(const float *samples, NSUInteger count, NSArray<VibeColor *> *spectrumColors,
                                       CGFloat width, CGFloat scale,
                                       std::vector<float> *barColors) CF_RETURNS_RETAINED;
static CGImageRef VibeNewSpectrumStrip(const float *samples, NSUInteger count, NSArray<VibeColor *> *spectrumColors,
                                       CGFloat width, CGFloat scale, std::vector<float> *barColors) {
    size_t pixels = (size_t)llround(width * scale);
    if (count == 0 || pixels == 0) {
        return NULL;
    }
    float primaries[3][3];
    VibeSpectrumPrimaries(spectrumColors, primaries);
    barColors->resize(count * 3);
    float *bar = barColors->data();
    for (NSUInteger i = 0; i < count; i++) {
        VibeSpectrumColor(samples + i * kAudioWaveformBandCount, primaries, bar + i * 3);
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:pixels * 4];
    uint8_t *pixel = (uint8_t *)bytes.mutableBytes;
    double step = (double)count / (double)pixels;
    for (size_t p = 0; p < pixels; p++, pixel += 4) {
        double position = clampRange(((double)p + 0.5) * step - 0.5, 0.0, (double)(count - 1));
        NSUInteger left = (NSUInteger)position;
        NSUInteger right = MIN(left + 1, count - 1);
        float t = (float)(position - (double)left);
        for (NSUInteger c = 0; c < 3; c++) {
            float value = bar[left * 3 + c] + (bar[right * 3 + c] - bar[left * 3 + c]) * t;
            pixel[c] = (uint8_t)lroundf(clampRange(value, 0.0f, 1.0f) * 255);
        }
        pixel[3] = 255;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef strip = CGImageCreate(pixels, 1, 8, 32, pixels * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return strip;
}

// A side's mask stops at its level, in the bar styles' ramp.
static NSArray *VibeThreeBandSideColors(CGFloat level, BOOL flat) {
    NSMutableArray *stops = [NSMutableArray array];
    for (VibeColor *color in VibeBarRampColors([VibeColor colorWithWhite:1 alpha:level], flat)) {
        [stops addObject:(id)color.CGColor];
    }
    return stops;
}

static id VibePinned(CALayer *layer, CGFloat scale) {
    layer.anchorPoint = CGPointZero;
    layer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null], @"hidden": [NSNull null]};
    layer.contentsScale = scale;
    return layer;
}

@implementation ThreeBandWaveformRenderer {
    CALayer *_container;
    // The seven band layers, drawn once, under one mask that gives each side
    // its level. It dims the composited stack, so the outer rings never show
    // through the inner ones. Spectrum's one strip, masked to the outline,
    // stands in their place.
    CALayer *_bands;
    CAShapeLayer *_bandLayers[kLayerCount];
    BOOL _spectrum;
    CALayer *_spectrumFill;
    CAShapeLayer *_spectrumOutline;
    // The primaries the strip was drawn with. They change only with the
    // appearance, and a theme resolves on every artwork change.
    NSArray<VibeColor *> *_stripColors;
    CALayer *_sides;
    CAGradientLayer *_playedSide;
    CAGradientLayer *_unplayedSide;
    // Masked to the outline, so the lit slice is the waveform's own column;
    // hidden, and so never composited nor its outline built, until hovered.
    CALayer *_hoverHost;
    CAShapeLayer *_hoverMask;
    CALayer *_hoverColumn;
    // Kept across morph frames so the vectors do not regrow per rebuild.
    std::vector<CGPoint> _points;
    std::vector<float> _barColors;
}

+ (NSString *)styleIdentifier {
    return @"three_band";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_THREE_BAND;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    return [self initWithLayer:parentLayer bounds:bounds isDark:isDark spectrum:NO];
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                     spectrum:(BOOL)spectrum {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        _spectrum = spectrum;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
                       rebuild:^{ [weakSelf rebuildPaths]; }];
        _morph.samplesPerBar = kAudioWaveformBandCount;
        [self setupLayers];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)dealloc {
    [_container removeFromSuperlayer];
}

- (void)setupLayers {
    CGFloat scale = self.parentLayer.contentsScale;
    _container = VibePinned([CALayer layer], scale);
    [self.parentLayer addSublayer:_container];

    _bands = VibePinned([CALayer layer], scale);
    [_container addSublayer:_bands];
    if (_spectrum) {
        _spectrumFill = VibePinned([CALayer layer], scale);
        // The strip is drawn at the backing's pixels. A filter could only
        // blur it.
        _spectrumFill.magnificationFilter = kCAFilterNearest;
        _spectrumFill.minificationFilter = kCAFilterNearest;
        _spectrumOutline = VibePinned([CAShapeLayer layer], scale);
        _spectrumOutline.fillColor = [VibeColor whiteColor].CGColor;
        _spectrumFill.mask = _spectrumOutline;
        [_bands addSublayer:_spectrumFill];
    } else {
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            _bandLayers[layer] = VibePinned([CAShapeLayer layer], scale);
            [_bands addSublayer:_bandLayers[layer]];
        }
    }
    _sides = VibePinned([CALayer layer], scale);
    _playedSide = VibePinned([CAGradientLayer layer], scale);
    _unplayedSide = VibePinned([CAGradientLayer layer], scale);
    for (CAGradientLayer *side in @[_playedSide, _unplayedSide]) {
        VibeAimBarGradient(side, self.centered);
        [_sides addSublayer:side];
    }
    _bands.mask = _sides;

    _hoverHost = VibePinned([CALayer layer], scale);
    _hoverHost.hidden = YES;
    _hoverMask = VibePinned([CAShapeLayer layer], scale);
    _hoverMask.fillColor = [VibeColor whiteColor].CGColor;
    _hoverHost.mask = _hoverMask;
    _hoverColumn = VibePinned([CALayer layer], scale);
    [_hoverHost addSublayer:_hoverColumn];
    [_container addSublayer:_hoverHost];
}

// The ramp's aim follows the anchoring.
- (void)setCentered:(BOOL)centered {
    if (self.centered == centered) return;
    [super setCentered:centered];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    VibeAimBarGradient(_playedSide, centered);
    VibeAimBarGradient(_unplayedSide, centered);
    [CATransaction commit];
}

// The theme gives the band fills in this layer order, or Spectrum's
// primaries. It gives the ramp, or none, and the hover slice, an affordance
// rather than a band.
- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer].fillColor = self.theme.bandColors[layer].CGColor;
    }
    _playedSide.colors = VibeThreeBandSideColors(1, self.theme.flatFill);
    _unplayedSide.colors = VibeThreeBandSideColors(kUnplayedOpacity, self.theme.flatFill);
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
    [CATransaction commit];
    if (_spectrum && _stripColors != self.theme.spectrumColors) {
        _stripColors = self.theme.spectrumColors;
        [_morph rebuildNow];
    }
}

// A bar a point, up to the waveform's chunks: the energy windows follow the
// drawn width rather than every bar style's 1/1024 floor, so a zoom resolves
// each kick where floored bars a beat long alias against it into a swell.
- (NSUInteger)barCountForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1));
    return clampRange(count, (NSUInteger)2, kVibeWaveformMaxBars);
}

+ (BOOL)readsBands {
    return YES;
}

- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    return VibeBarSeekHitBand(bounds);
}

- (void)setHoverHighlightX:(CGFloat)x {
    [super setHoverHighlightX:x];
    CGRect b = self.parentLayer.bounds;
    BOOL wasHidden = _hoverHost.hidden;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (x < 0 || b.size.width <= 0) {
        _hoverHost.hidden = YES;
    } else {
        CGRect column = VibeSnappedColumnRect(x, kVibeHoverHighlightWidth, b.size.width, b.size.height,
                                              VibeBackingScaleForLayer(self.parentLayer));
        _hoverColumn.bounds = CGRectMake(0, 0, column.size.width, column.size.height);
        _hoverColumn.position = column.origin;
        _hoverHost.hidden = NO;
    }
    [CATransaction commit];
    // Spectrum's rebuilds keep the hover outline current.
    if (wasHidden && !_hoverHost.hidden && !_spectrum) {
        [_morph rebuildNow];
    }
}

- (void)backingScaleDidChange {
    [super backingScaleDidChange];
    [self setHoverHighlightX:self.hoverHighlightX];
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    CGRect b = self.parentLayer.bounds;
    CGFloat played = clampRange(b.size.width * progress, 0, b.size.width);
    _playedSide.frame = CGRectMake(0, 0, played, b.size.height);
    _unplayedSide.frame = CGRectMake(played, 0, b.size.width - played, b.size.height);
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    CGRect local = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    // Implicit animations would leave the waveform chasing an animated window
    // resize.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in @[_container, _bands, _sides, _hoverHost, _hoverMask]) {
        layer.frame = local;
    }
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer].frame = local;
    }
    _spectrumFill.frame = local;
    _spectrumOutline.frame = local;
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];
    [self setHoverHighlightX:self.hoverHighlightX];

    NSUInteger count = [self barCountForWidth:bounds.size.width];
    [_morph updateTargetForSize:bounds.size identity:waveform count:count * kAudioWaveformBandCount
                           fill:^(std::vector<float> &target) {
        [self fillBandLevels:target.data() count:count waveform:waveform];
    }];
}

// A bar's window slides to take a hit whole up to this many bars, and not at
// all from twice as many, where a bar is two chunks or fewer and draws each
// kick as it is.
static const NSUInteger kFullReachBars = kVibeWaveformMaxBars / 4;

// Each bar's levels are its own window's (barCountForWidth:), held still
// through a resize by its reach. The mean squares land in out first, so
// Normalize reads them where the bars are its columns. Normalize and Gain
// apply to all three bands alike.
- (void)fillBandLevels:(float *)out count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    waveform->getBarMeanSquares(count, VibeWaveformWindowReach(count, kFullReachBars), NULL, out);
    float fullScaleRMS = [self bandFullScaleRMSForWaveform:waveform count:count meanSquares:out];
    float gainDB = self.gainDB;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        float bandFullScaleRMS = fullScaleRMS * kBandShareOfFullScale[b];
        for (float *level = out + b; level < out + count * kAudioWaveformBandCount; level += kAudioWaveformBandCount) {
            *level = VibeWaveformBarLevel(*level, bandFullScaleRMS, gainDB);
        }
    }
}

// Normalize's reference is the loudest band against its share, so the tallest
// band at the track's loudest column draws at full height: the full mix's
// reference left every band short of it. It keeps
// VibeWaveformFullScaleRMSForColumns's rules — the whole track, the 1,024
// columns, the fixed ceiling — but is its own so that within the columns it
// reads the mean squares the fill just took: measuring them through the
// waveform again cost a fifth of every resize frame's instructions. Past the
// columns it measures 1,024 of them the same way, so the reference does not
// step as a resize crosses 1,024 bars.
- (float)bandFullScaleRMSForWaveform:(AudioWaveform *)waveform count:(NSUInteger)count
                         meanSquares:(const float *)drawn {
    if (!self.normalizesLevels || !waveform->isComplete()) {
        return kVibeWaveformFullScaleRMS;
    }
    std::vector<float> columns;
    if (count > kVibeWaveformEnergyColumns) {
        count = kVibeWaveformEnergyColumns;
        columns.resize(count * kAudioWaveformBandCount);
        waveform->getBarMeanSquares(count, VibeWaveformWindowReach(count, kFullReachBars), NULL, columns.data());
        drawn = columns.data();
    }
    float loudest = 0;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        float maximum = 0;
        vDSP_maxv(drawn + b, kAudioWaveformBandCount, &maximum, count);
        loudest = fmaxf(loudest, sqrtf(maximum) / kBandShareOfFullScale[b]);
    }
    return VibeWaveformNormalizedFullScaleRMS(loudest);
}

// The morph's rebuild callback.
- (void)rebuildPaths {
    const std::vector<float> &samples = [_morph displayedSamples];
    NSUInteger count = samples.size() / kAudioWaveformBandCount;
    if (count == 0) {
        return;
    }
    VibeSignpostBegin(waveform_path);
    // Spectrum fills the outline. Otherwise only the hover slice reads it, and
    // setHoverHighlightX: rebuilds as the slice appears.
    CGMutablePathRef outline = _spectrum || !_hoverHost.hidden ? CGPathCreateMutable() : NULL;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_spectrum) {
        VibeAddThreeBandPaths(NULL, outline, &_points, _morph.size, samples.data(), count, _morph.barMinHeight,
                              self.centered);
        CGImageRef strip = VibeNewSpectrumStrip(samples.data(), count, _stripColors, _morph.size.width,
                                                VibeBackingScaleForLayer(self.parentLayer), &_barColors);
        _spectrumOutline.path = outline;
        _spectrumFill.contents = (__bridge id)strip;
        CGImageRelease(strip);
    } else {
        CGMutablePathRef paths[kLayerCount];
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            paths[layer] = CGPathCreateMutable();
        }
        VibeAddThreeBandPaths(paths, outline, &_points, _morph.size, samples.data(), count, _morph.barMinHeight,
                              self.centered);
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            _bandLayers[layer].path = paths[layer];
            CGPathRelease(paths[layer]);
        }
    }
    if (outline) {
        _hoverMask.path = outline;
        CGPathRelease(outline);
    }
    [CATransaction commit];
    VibeSignpostEnd(waveform_path);
}

#pragma mark - Envelope bitmap

// Every band scales by its own reference (bandFullScaleRMSForWaveform:), read
// at the floor's 1,024 columns.
- (CGFloat)normalizationGainForWaveform:(AudioWaveform *)waveform {
    if (!self.normalizesLevels || !waveform || !waveform->isComplete()) {
        return 1;
    }
    NSUInteger count = kVibeWaveformEnergyColumns;
    std::vector<float> columns(count * kAudioWaveformBandCount);
    waveform->getBarMeanSquares(count, VibeWaveformWindowReach(count, kFullReachBars), NULL, columns.data());
    float reference = [self bandFullScaleRMSForWaveform:waveform count:count meanSquares:columns.data()];
    return reference > 0 ? kVibeWaveformFullScaleRMS / reference : 1;
}

- (BOOL)supportsEnvelopeBake {
    return YES;
}

- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform {
    // The live count for the host's width, so the bake matches the layers it
    // replaces.
    NSUInteger count = [self barCountForWidth:self.parentLayer.bounds.size.width];
    NSMutableData *data = [NSMutableData dataWithLength:count * kAudioWaveformBandCount * sizeof(float)];
    [self fillBandLevels:(float *)data.mutableBytes count:count waveform:waveform];
    return data;
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    NSUInteger count = samples.length / (kAudioWaveformBandCount * sizeof(float));
    CGContextRef ctx = count ? VibeNewEnvelopeBitmapContext(size, scale) : NULL;
    if (!ctx) {
        return NULL;
    }
    const float *bars = (const float *)samples.bytes;
    std::vector<CGPoint> points;
    if (_spectrum) {
        CGMutablePathRef outline = CGPathCreateMutable();
        VibeAddThreeBandPaths(NULL, outline, &points, size, bars, count, 1, self.centered);
        // The theme's colors, not _stripColors: a bake may run off main.
        std::vector<float> barColors;
        CGImageRef strip = VibeNewSpectrumStrip(bars, count, self.theme.spectrumColors, size.width, scale,
                                                &barColors);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, outline);
        CGContextClip(ctx);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGContextDrawImage(ctx, CGRectMake(0, 0, size.width, size.height), strip);
        CGContextRestoreGState(ctx);
        CGImageRelease(strip);
        CGPathRelease(outline);
    } else {
        CGMutablePathRef paths[kLayerCount];
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            paths[layer] = CGPathCreateMutable();
        }
        VibeAddThreeBandPaths(paths, NULL, &points, size, bars, count, 1, self.centered);
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            if (!CGPathIsEmpty(paths[layer])) {
                CGContextAddPath(ctx, paths[layer]);
                CGContextSetFillColorWithColor(ctx, self.theme.bandColors[layer].CGColor);
                CGContextFillPath(ctx);
            }
            CGPathRelease(paths[layer]);
        }
    }
    if (!self.theme.flatFill) {
        // The played side's mask, so the bake matches the live layers.
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
        VibeFillBarGradient(ctx, size, VibeThreeBandSideColors(1, NO), self.centered);
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

// The unplayed side is the played bitmap dimmed, as the live stack is.
- (CGFloat)unplayedOverPlayedOpacity {
    return kUnplayedOpacity;
}

@end
