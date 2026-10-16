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
static const float kBandShareOfFullScale[wavecore::kBandCount] = {1.0f, 0.48f, 0.48f};

// Spectrum's columns carry their color levels after their heights.
static const NSUInteger kSpectrumSamplesPerBar = 2 * wavecore::kBandCount;

static const float kUnplayedOpacity = 0.5f;

// Painter's order — singles, pairs, all three — so at every height the layer
// on top is the set of bands reaching it. Bit 0 is low, 1 mid, 2 high.
static const NSUInteger kLayerCount = 7;
static const NSUInteger kBandsForLayer[kLayerCount] = {1, 2, 4, 3, 5, 6, 7};

// A column's window slides to take a hit whole up to this many columns across
// the track, and not at all from twice as many, where a column is two base
// bins or fewer and draws each kick as it is.
static const NSUInteger kFullReachBars = 2048;

// Silence keeps the all-bands hairline.
static CGFloat VibeThreeBandHalves(const float *bar, CGFloat vscale, CGFloat minimumHeight, CGFloat *half) {
    CGFloat tallest = 0;
    for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
        half[b] = clampRange((CGFloat)bar[b], 0, 1) * vscale;
        tallest = MAX(tallest, half[b]);
    }
    if (tallest * 2 < minimumHeight) {
        tallest = minimumHeight / 2;
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) half[b] = tallest;
    }
    return tallest;
}

static void VibeSRGBComponents(VibeColor *color, float *rgb) {
    CGFloat components[3] = {};
    VibeColorGetSRGB(color, &components[0], &components[1], &components[2]);
    for (NSUInteger c = 0; c < 3; c++) {
        rgb[c] = (float)components[c];
    }
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
    // Dim the composited picture so outer rings cannot show through inner
    // ones.
    CALayer *_bands;
    // The bands painted over the render window: the seven rings, or
    // Spectrum's mixes inside the tallest band.
    CALayer *_picture;
    BOOL _spectrum;
    NSUInteger _samplesPerBar;
    // The fills in sRGB, kept until the theme changes them.
    NSArray<VibeColor *> *_fillColors;
    float _fills[kLayerCount][3];
    CALayer *_sides;
    CAGradientLayer *_playedSide;
    CAGradientLayer *_unplayedSide;
    // Masked by the picture, so the lit slice is the waveform's own column;
    // hidden, and so never composited, until hovered.
    CALayer *_hoverHost;
    CALayer *_hoverMask;
    CALayer *_hoverColumn;
    VibeRenderPixels _drawnPixels;
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
        _samplesPerBar = _spectrum ? kSpectrumSamplesPerBar : wavecore::kBandCount;
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
                       rebuild:^{ [weakSelf rebuildPicture]; }];
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
    _picture = VibePinned([CALayer layer], scale);
    [_bands addSublayer:_picture];
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
    _hoverMask = VibePinned([CALayer layer], scale);
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
    _playedSide.colors = VibeThreeBandSideColors(1, [self drawsFlat]);
    _unplayedSide.colors = VibeThreeBandSideColors(kUnplayedOpacity, [self drawsFlat]);
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
    [CATransaction commit];
    // The fills are painted into the picture, so new ones redraw it.
    NSArray<VibeColor *> *fills = _spectrum ? self.theme.spectrumColors : self.theme.bandColors;
    if (![_fillColors isEqualToArray:fills]) {
        _fillColors = fills;
        for (NSUInteger i = 0; i < MIN(fills.count, kLayerCount); i++) {
            VibeSRGBComponents(fills[i], _fills[i]);
        }
        [_morph rebuildNow];
    }
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
    for (CALayer *layer in @[_container, _bands, _sides, _hoverHost]) {
        layer.frame = local;
    }
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];
    [self setHoverHighlightX:self.hoverHighlightX];

    _pixels = [self renderPixelsForSize:bounds.size];
    // A column a point for 3-Band, so zoomed in it resolves each hit; a column
    // a pixel for Spectrum, whose colors change from pixel to pixel.
    double columnsPerPixel = _spectrum ? 1 : 1 / _pixels.scale;
    [self updateStepTargetForSize:bounds.size waveform:waveform columnsPerPixel:columnsPerPixel
                           stride:_samplesPerBar fill:^(float *out, const wavecore::StepPart &part) {
        [self fillBandLevels:out part:part waveform:waveform];
    }];
    if (!(_drawnPixels == _pixels)) {
        [_morph rebuildNow];
    }
}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {
    [self dipStepColumnsFromFraction:from toFraction:to stride:_samplesPerBar];
}

// Heights use the reach window. Spectrum colors use a window of their own,
// floored at kVibeWaveformSpectrumColorColumns and unclamped.
- (void)fillBandLevels:(float *)out part:(const wavecore::StepPart &)part waveform:(AudioWaveform *)waveform {
    NSUInteger count = part.count;
    double frames = part.framesPerColumn();
    std::vector<float> scratch(_spectrum ? count * kSpectrumSamplesPerBar : 0);
    float *heights = _spectrum ? scratch.data() : out;
    float *colors = heights + count * wavecore::kBandCount;
    double total = (double)waveform->totalFrames();
    float reach = VibeWaveformWindowReach((NSUInteger)llround(total / frames), kFullReachBars);
    waveform->meanSquares(frames, part.first, count, reach, NULL, heights);
    float fullScaleRMS = [self bandFullScaleRMSForWaveform:waveform];
    float gainDB = self.gainDB;
    for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
        float bandFullScaleRMS = fullScaleRMS * kBandShareOfFullScale[b];
        for (float *level = heights + b; level < colors; level += wavecore::kBandCount) {
            *level = VibeWaveformBarLevel(*level, bandFullScaleRMS, gainDB);
        }
    }
    if (!_spectrum) {
        return;
    }
    double halfWidth = fmax(frames, total / kVibeWaveformSpectrumColorColumns / 2);
    waveform->tentBandMeanSquares(frames, part.first, count, halfWidth, colors);
    for (NSUInteger i = 0; i < count; i++) {
        float *bar = out + i * kSpectrumSamplesPerBar;
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            bar[b] = heights[i * wavecore::kBandCount + b];
            float meanSquare = fmaxf(colors[i * wavecore::kBandCount + b], 0);
            bar[wavecore::kBandCount + b] = sqrtf(meanSquare) / (fullScaleRMS * kBandShareOfFullScale[b]);
        }
    }
}

// Normalize against the loudest band relative to its share, read from the
// track's own 1,024 columns, so no view's width can move it. The waveform
// keeps that answer.
- (float)bandFullScaleRMSForWaveform:(AudioWaveform *)waveform {
    if (!self.normalizesLevels || !waveform->isComplete()) {
        return kVibeWaveformFullScaleRMS;
    }
    float maxima[wavecore::kBandCount];
    waveform->loudestMeanSquares(kVibeWaveformEnergyColumns,
            VibeWaveformWindowReach(kVibeWaveformEnergyColumns, kFullReachBars), NULL, maxima);
    float loudest = 0;
    for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
        loudest = fmaxf(loudest, sqrtf(maxima[b]) / kBandShareOfFullScale[b]);
    }
    return VibeWaveformNormalizedFullScaleRMS(loudest);
}

// The morph's rebuild callback. Each pixel column reads the two steps
// linearly between their columns' centers, crossfaded, and paints the sets of
// bands in order; the fill's coverage smooths their tops.
- (void)rebuildPicture {
    const std::vector<float> &displayed = [_morph displayedSamples];
    VibeRenderPixels pixels = _pixels;
    _drawnPixels = pixels;
    wavecore::StepWindow window = _window;
    NSUInteger stride = _samplesPerBar;
    CGImageRef image = NULL;
    VibeSignpostBegin(waveform_raster);
    if (!displayed.empty() && displayed.size() == window.columnCount() * stride && pixels.width() > 0 &&
        pixels.height > 0) {
        const float *samples = displayed.data();
        double framesPerPixel = [self framesPerPixel];
        CGFloat height = pixels.height;
        CGFloat midY = height / 2, baseline = VibeBarBaseline(height), vscale = VibeBarVScale(height);
        CGFloat minimum = _morph.barMinHeight * pixels.scale;
        BOOL centered = self.centered, spectrum = _spectrum;
        float fills[kLayerCount][3];
        memcpy(fills, _fills, sizeof(fills));
        image = VibeNewLayerImage(_picture.contentsAreFlipped, (size_t)pixels.width(), (size_t)pixels.height,
                                  [&](uint32_t *out, ptrdiff_t rowStride) {
            wavecore::ColumnPaint column(pixels.height);
            for (int x = pixels.x0; x < pixels.x1; x++) {
                column.clear();
                float bar[kSpectrumSamplesPerBar] = {};
                double center = (x + 0.5) * framesPerPixel;
                float weights = 0;
                size_t offset = 0;
                for (int p = 0; p < 2; p++) {
                    const wavecore::StepPart &part = window.parts[p];
                    float weight = (float)(p ? window.coarse : 1 - window.coarse);
                    if (weight > 0 && part.count > 0) {
                        wavecore::ColumnPair pair = wavecore::ColumnPairAroundFrame(center, part);
                        const float *left = samples + (offset + pair.left) * stride;
                        const float *right = samples + (offset + pair.right) * stride;
                        for (NSUInteger k = 0; k < stride; k++) {
                            bar[k] += weight * (left[k] + (right[k] - left[k]) * pair.toRight);
                        }
                        weights += weight;
                    }
                    offset += part.count;
                }
                if (weights > 0) {
                    for (NSUInteger k = 0; k < stride; k++) bar[k] /= weights;
                }
                CGFloat half[wavecore::kBandCount];
                CGFloat tallest = VibeThreeBandHalves(bar, vscale, minimum, half);
                if (spectrum) {
                    float rgb[3];
                    VibeSpectrumColor(bar + wavecore::kBandCount, fills, rgb);
                    CGFloat bottom = centered ? midY - tallest : baseline;
                    column.paintSpan(bottom, bottom + 2 * tallest, rgb[0], rgb[1], rgb[2]);
                } else {
                    CGFloat lowMid = MIN(half[0], half[1]);
                    const CGFloat heights[8] = {tallest, half[0], half[1], lowMid, half[2], MIN(half[0], half[2]),
                                                MIN(half[1], half[2]), MIN(lowMid, half[2])};
                    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
                        CGFloat h = heights[kBandsForLayer[layer]];
                        CGFloat bottom = centered ? midY - h : baseline;
                        column.paintSpan(bottom, bottom + 2 * h, fills[layer][0], fills[layer][1], fills[layer][2]);
                    }
                }
                column.write(out + (x - pixels.x0), rowStride);
            }
        });
    }
    CGRect frame = pixels.frameForHeight(_morph.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _picture.frame = frame;
    _picture.contents = (__bridge id)image;
    _hoverMask.frame = frame;
    _hoverMask.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
    VibeSignpostEnd(waveform_raster);
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
