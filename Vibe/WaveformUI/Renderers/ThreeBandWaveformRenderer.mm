//
//  ThreeBandWaveformRenderer.mm
//  Vibe
//

#import "ThreeBandWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "VibeStrings.h"

#include <vector>
#include <cmath>

// Smaller mid and high shares keep those weaker bands visible beside lows.
static const float kBandShareOfFullScale[kAudioWaveformBandCount] = {1.0f, 0.48f, 0.48f};

// Spectrum's bars carry their color levels after their heights.
static const NSUInteger kSpectrumSamplesPerBar = 2 * kAudioWaveformBandCount;

static const float kUnplayedOpacity = 0.5f;

// Painter's order — singles, pairs, all three — so at every height the layer
// on top is the set of bands reaching it. Bit 0 is low, 1 mid, 2 high.
static const NSUInteger kLayerCount = 7;
static const NSUInteger kLayerForBands[8] = {0, 0, 1, 3, 2, 4, 5, 6};

// Silence keeps the all-bands hairline.
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

// Nested band sets paint in order through the bar centers.
// The optional outline follows the tallest band. Spectrum fills only it.
// Live layers and bakes share this geometry and the caller's scratch.
static void VibeAddThreeBandPaths(CGMutablePathRef *paths, CGMutablePathRef outline, std::vector<CGPoint> *points,
                                  CGSize size, const float *samples, NSUInteger count, NSUInteger stride,
                                  CGFloat minimumHeight, BOOL centered) {
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
    NSUInteger polygonLength = 2 * count + 4;
    points->resize(end * polygonLength);
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat half[kAudioWaveformBandCount];
        CGFloat tallest = VibeThreeBandHalves(samples + i * stride, vscale, minimumHeight, half);
        CGFloat x = pitch * ((CGFloat)i + 0.5);
        CGFloat lowMid = MIN(half[0], half[1]);
        const CGFloat heights[8] = {tallest, half[0], half[1], lowMid, half[2], MIN(half[0], half[2]),
                                    MIN(half[1], half[2]), MIN(lowMid, half[2])};
        for (NSUInteger mask = first; mask < end; mask++) {
            CGPoint *polygon = points->data() + mask * polygonLength;
            CGFloat bottom = centered ? midY - heights[mask] : baseline;
            polygon[1 + i] = CGPointMake(x, bottom + 2 * heights[mask]);
            polygon[polygonLength - 2 - i] = CGPointMake(x, bottom);
        }
    }
    for (NSUInteger mask = first; mask < end; mask++) {
        CGMutablePathRef path = mask ? paths[kLayerForBands[mask]] : outline;
        CGPoint *polygon = points->data() + mask * polygonLength;
        polygon[0] = CGPointMake(0, polygon[1].y);
        polygon[count + 1] = CGPointMake(size.width, polygon[count].y);
        polygon[count + 2] = CGPointMake(size.width, polygon[count + 3].y);
        polygon[polygonLength - 1] = CGPointMake(0, polygon[polygonLength - 2].y);
        CGPathAddLines(path, NULL, polygon, polygonLength);
        CGPathCloseSubpath(path);
    }
}

static void VibeSpectrumPrimaries(NSArray<VibeColor *> *colors, float primaries[3][3]) {
    for (NSUInteger band = 0; band < kAudioWaveformBandCount; band++) {
        CGFloat rgb[3] = {};
        VibeColorGetSRGB(colors[band], &rgb[0], &rgb[1], &rgb[2]);
        for (NSUInteger c = 0; c < 3; c++) {
            primaries[band][c] = (float)rgb[c];
        }
    }
}

// One row at backing resolution, interpolated between bar centers.
// Color levels follow the heights in each bar's samples.
static CGImageRef VibeNewSpectrumStrip(const float *samples, NSUInteger count, const float primaries[3][3],
                                       CGFloat width, CGFloat scale) CF_RETURNS_RETAINED;
static CGImageRef VibeNewSpectrumStrip(const float *samples, NSUInteger count, const float primaries[3][3],
                                       CGFloat width, CGFloat scale) {
    size_t pixels = (size_t)llround(width * scale);
    if (count == 0 || pixels == 0) {
        return NULL;
    }
    // Live bars match backing pixels until the bar cap. Only a stretched
    // strip needs colors held for interpolation.
    std::vector<float> bar(count == pixels ? 0 : count * 3);
    for (NSUInteger i = 0; !bar.empty() && i < count; i++) {
        VibeSpectrumColor(samples + i * kSpectrumSamplesPerBar + kAudioWaveformBandCount, primaries, &bar[i * 3]);
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:pixels * 4];
    uint8_t *pixel = (uint8_t *)bytes.mutableBytes;
    double step = (double)count / (double)pixels;
    for (size_t p = 0; p < pixels; p++, pixel += 4) {
        float rgb[3];
        if (bar.empty()) {
            VibeSpectrumColor(samples + p * kSpectrumSamplesPerBar + kAudioWaveformBandCount, primaries, rgb);
        } else {
            double position = clampRange(((double)p + 0.5) * step - 0.5, 0.0, (double)(count - 1));
            NSUInteger left = (NSUInteger)position;
            NSUInteger right = MIN(left + 1, count - 1);
            float t = (float)(position - (double)left);
            for (NSUInteger c = 0; c < 3; c++) {
                rgb[c] = bar[left * 3 + c] + (bar[right * 3 + c] - bar[left * 3 + c]) * t;
            }
        }
        for (NSUInteger c = 0; c < 3; c++) {
            pixel[c] = (uint8_t)lroundf(clampRange(rgb[c], 0.0f, 1.0f) * 255);
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
    // Dim the composited stack so outer rings cannot show through inner ones.
    // Spectrum uses one masked strip in place of the seven band layers.
    CALayer *_bands;
    CAShapeLayer *_bandLayers[kLayerCount];
    BOOL _spectrum;
    NSUInteger _samplesPerBar;
    CALayer *_spectrumFill;
    CAShapeLayer *_spectrumOutline;
    // Reuse the strip when artwork changes leave its primaries unchanged.
    NSArray<VibeColor *> *_stripColors;
    float _stripPrimaries[3][3];
    CALayer *_sides;
    CAGradientLayer *_playedSide;
    CAGradientLayer *_unplayedSide;
    // Masked to the outline, so the lit slice is the waveform's own column;
    // hidden, and so never composited nor its outline built, until hovered.
    CALayer *_hoverHost;
    CAShapeLayer *_hoverMask;
    CALayer *_hoverColumn;
    // Kept across morph frames so the vector does not regrow per rebuild.
    std::vector<CGPoint> _points;
    // Compare-only identity, as in the morph. Samples are immutable.
    const AudioWaveform *_referenceWaveform;
    float _referenceRMS;
}

+ (NSString *)styleIdentifier {
    return @"three_band";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_THREE_BAND;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        _spectrum = [self.class paletteKind] == VibeWaveformPaletteKindSpectrum;
        _samplesPerBar = _spectrum ? kSpectrumSamplesPerBar : kAudioWaveformBandCount;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
                       rebuild:^{ [weakSelf rebuildPaths]; }];
        _morph.samplesPerBar = _samplesPerBar;
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

- (void)setCentered:(BOOL)centered {
    if (self.centered == centered) return;
    [super setCentered:centered];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    VibeAimBarGradient(_playedSide, centered);
    VibeAimBarGradient(_unplayedSide, centered);
    [CATransaction commit];
}

- (BOOL)drawsFlat {
    return self.theme.flatFill || _spectrum;
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer].fillColor = self.theme.bandColors[layer].CGColor;
    }
    _playedSide.colors = VibeThreeBandSideColors(1, [self drawsFlat]);
    _unplayedSide.colors = VibeThreeBandSideColors(kUnplayedOpacity, [self drawsFlat]);
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
    [CATransaction commit];
    if (_spectrum && ![_stripColors isEqualToArray:self.theme.spectrumColors]) {
        _stripColors = self.theme.spectrumColors;
        VibeSpectrumPrimaries(_stripColors, _stripPrimaries);
        [_morph rebuildNow];
    }
}

// Use per-bar windows so zoom can resolve individual hits.
// Spectrum samples per backing pixel; 3-Band samples per point.
// Both cap at kVibeWaveformMaxBars, independent of the chunk count.
- (NSUInteger)barCountForWidth:(CGFloat)width {
    CGFloat scale = _spectrum ? VibeBackingScaleForLayer(self.parentLayer) : 1;
    NSUInteger count = (NSUInteger)llround(clampMin(width * scale, 1));
    return clampRange(count, (NSUInteger)2, kVibeWaveformMaxBars);
}

+ (VibeWaveformPaletteKind)paletteKind {
    return VibeWaveformPaletteKindBands;
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
    if (!waveform) {
        _referenceWaveform = nullptr;
        _referenceRMS = 0;
    }
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
    [_morph updateTargetForSize:bounds.size identity:waveform count:count * _samplesPerBar
                           fill:^(std::vector<float> &target) {
        [self fillBandLevels:target.data() count:count waveform:waveform];
    }];
}

// A bar's window slides to take a hit whole up to this many bars, and not at
// all from twice as many, where a bar is two chunks or fewer and draws each
// kick as it is.
static const NSUInteger kFullReachBars = kVibeWaveformMaxBars / 4;

// Heights use the reach window. Spectrum colors use a window of their own,
// floored at kVibeWaveformSpectrumColorColumns and unclamped.
- (void)fillBandLevels:(float *)out count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    std::vector<float> scratch(_spectrum ? count * kSpectrumSamplesPerBar : 0);
    float *heights = _spectrum ? scratch.data() : out;
    float *colors = heights + count * kAudioWaveformBandCount;
    waveform->getBarMeanSquares(count, VibeWaveformWindowReach(count, kFullReachBars), NULL, heights);
    float fullScaleRMS = [self bandFullScaleRMSForWaveform:waveform count:count meanSquares:heights];
    float gainDB = self.gainDB;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        float bandFullScaleRMS = fullScaleRMS * kBandShareOfFullScale[b];
        for (float *level = heights + b; level < colors; level += kAudioWaveformBandCount) {
            *level = VibeWaveformBarLevel(*level, bandFullScaleRMS, gainDB);
        }
    }
    if (!_spectrum) {
        return;
    }
    waveform->getBandWindowMeanSquares(count, kVibeWaveformSpectrumColorColumns, colors);
    for (NSUInteger i = 0; i < count; i++) {
        float *bar = out + i * kSpectrumSamplesPerBar;
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            bar[b] = heights[i * kAudioWaveformBandCount + b];
            float meanSquare = fmaxf(colors[i * kAudioWaveformBandCount + b], 0);
            bar[kAudioWaveformBandCount + b] = sqrtf(meanSquare) / (fullScaleRMS * kBandShareOfFullScale[b]);
        }
    }
}

// Normalize against the loudest band relative to its share.
// Reuse the fill's mean squares up to 1,024 bars. Beyond that, measure
// 1,024 columns to keep the reference stable across resizes.
- (float)bandFullScaleRMSForWaveform:(AudioWaveform *)waveform count:(NSUInteger)count
                         meanSquares:(const float *)drawn {
    if (_referenceWaveform != waveform) {
        _referenceWaveform = waveform;
        _referenceRMS = 0;
    }
    if (!self.normalizesLevels || !waveform->isComplete()) {
        return kVibeWaveformFullScaleRMS;
    }
    BOOL fixedReference = count >= kVibeWaveformEnergyColumns;
    if (fixedReference && _referenceRMS > 0) {
        return _referenceRMS;
    }
    std::vector<float> columns;
    if (count > kVibeWaveformEnergyColumns || !drawn) {
        count = MIN(count, kVibeWaveformEnergyColumns);
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
    float reference = VibeWaveformNormalizedFullScaleRMS(loudest);
    if (fixedReference) _referenceRMS = reference;
    return reference;
}

- (void)rebuildPaths {
    const std::vector<float> &samples = [_morph displayedSamples];
    NSUInteger count = samples.size() / _samplesPerBar;
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
        VibeAddThreeBandPaths(NULL, outline, &_points, _morph.size, samples.data(), count, _samplesPerBar,
                              _morph.barMinHeight, self.centered);
        CGImageRef strip = VibeNewSpectrumStrip(samples.data(), count, _stripPrimaries, _morph.size.width,
                                                VibeBackingScaleForLayer(self.parentLayer));
        _spectrumOutline.path = outline;
        _spectrumFill.contents = (__bridge id)strip;
        CGImageRelease(strip);
    } else {
        CGMutablePathRef paths[kLayerCount];
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            paths[layer] = CGPathCreateMutable();
        }
        VibeAddThreeBandPaths(paths, outline, &_points, _morph.size, samples.data(), count, _samplesPerBar,
                              _morph.barMinHeight, self.centered);
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
    float reference = [self bandFullScaleRMSForWaveform:waveform count:kVibeWaveformEnergyColumns meanSquares:NULL];
    return reference > 0 ? kVibeWaveformFullScaleRMS / reference : 1;
}

- (BOOL)supportsEnvelopeBake {
    return YES;
}

- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform {
    // The live count for the host's width, so the bake matches the layers it
    // replaces.
    NSUInteger count = [self barCountForWidth:self.parentLayer.bounds.size.width];
    NSMutableData *data = [NSMutableData dataWithLength:count * _samplesPerBar * sizeof(float)];
    [self fillBandLevels:(float *)data.mutableBytes count:count waveform:waveform];
    return data;
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    NSUInteger count = samples.length / (_samplesPerBar * sizeof(float));
    CGContextRef ctx = count ? VibeNewEnvelopeBitmapContext(size, scale) : NULL;
    if (!ctx) {
        return NULL;
    }
    const float *bars = (const float *)samples.bytes;
    std::vector<CGPoint> points;
    if (_spectrum) {
        CGMutablePathRef outline = CGPathCreateMutable();
        VibeAddThreeBandPaths(NULL, outline, &points, size, bars, count, _samplesPerBar, 1, self.centered);
        // The theme's colors, not _stripPrimaries: a bake may run off main.
        float primaries[3][3];
        VibeSpectrumPrimaries(self.theme.spectrumColors, primaries);
        CGImageRef strip = VibeNewSpectrumStrip(bars, count, primaries, size.width, scale);
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
        VibeAddThreeBandPaths(paths, NULL, &points, size, bars, count, _samplesPerBar, 1, self.centered);
        for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
            if (!CGPathIsEmpty(paths[layer])) {
                CGContextAddPath(ctx, paths[layer]);
                CGContextSetFillColorWithColor(ctx, self.theme.bandColors[layer].CGColor);
                CGContextFillPath(ctx);
            }
            CGPathRelease(paths[layer]);
        }
    }
    if (![self drawsFlat]) {
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

@implementation SpectrumWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"spectrum";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_SPECTRUM;
}

+ (VibeWaveformPaletteKind)paletteKind {
    return VibeWaveformPaletteKindSpectrum;
}

@end
