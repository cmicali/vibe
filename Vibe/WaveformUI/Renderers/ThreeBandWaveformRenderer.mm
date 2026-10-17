//
//  ThreeBandWaveformRenderer.mm
//  Vibe
//

#import "ThreeBandWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "VibeStrings.h"
#import "WaveformZoomMath.h"

#include <functional>
#include <vector>
#include <cmath>

// Each band's height tops out at its ceiling: the lows the whole band, the
// mids three quarters, the highs half. So the bands nest as a DJ's waveform
// does, the lows outside, and the highs show as each hit's tip.
static const float kBandCeiling[wavecore::kBandCount] = {1.0f, 0.75f, 0.5f};

// Each band's share of the fixed full scale, from a typical mix's balance.
// Without Normalize each band is measured against its share, and Spectrum's
// color levels divide by it. Both weigh the mids and highs up against music's
// falling spectrum.
static const float kBandShareOfFullScale[wavecore::kBandCount] = {1.0f, 0.48f, 0.48f};

// Spectrum's columns carry their outline's height, then their color levels.
static const NSUInteger kSpectrumSamplesPerBar = 1 + wavecore::kBandCount;

static const float kUnplayedOpacity = 0.5f;

// Painter's order — singles, pairs, all three — so at every height the layer
// on top is the set of bands reaching it. Bit 0 is low, 1 mid, 2 high.
static const NSUInteger kLayerCount = 7;
static const NSUInteger kBandsForLayer[kLayerCount] = {1, 2, 4, 3, 5, 6, 7};

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

// A fill's components in the picture's space, or sRGB's for NULL.
static void VibeFillComponents(VibeColor *color, CGColorSpaceRef space, float *rgb) {
    CGFloat components[3] = {};
    CGColorRef matched = space ? CGColorCreateCopyByMatchingToColorSpace(space, kCGRenderingIntentDefault,
                                                                         color.CGColor, NULL)
                               : NULL;
    if (matched && CGColorGetNumberOfComponents(matched) == 4) {
        memcpy(components, CGColorGetComponents(matched), sizeof(components));
    } else {
        VibeColorGetSRGB(color, &components[0], &components[1], &components[2]);
    }
    CGColorRelease(matched);
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

// The grid fits the sections. Each edge then moves to the change in the
// bands' levels within two columns of it, read a bin at a time, never past
// halfway to a neighbor's. A section is colored by the mean of the grid
// columns whose centers it holds. The grid spans the length a streaming load
// will reach, so a delivery never moves a column.
std::vector<VibeSpectrumSection> VibeSpectrumSections(AudioWaveform *waveform) {
    std::vector<VibeSpectrumSection> sections;
    double total = (double)waveform->totalFrames();
    double gridFrames = VibeWaveformSectionFramesPerColumn(total, waveform->sampleRate());
    if (!(gridFrames > 0)) {
        return sections;
    }
    NSUInteger columns = (NSUInteger)clampRange(ceil(total / gridFrames), 1.0, (double)kVibeWaveformSectionColumns);
    std::vector<float> grid(columns * wavecore::kBandCount);
    waveform->tentBandMeanSquares(gridFrames, 0, columns, gridFrames, grid.data());
    NSUInteger starts[kVibeWaveformSectionColumns];
    NSUInteger count = VibeWaveformSectionStarts(grid.data(), columns, kBandShareOfFullScale, starts);
    sections.resize(count);
    double cell = waveform->binFrames();
    std::vector<float> levels;
    for (NSUInteger s = 0; s < count; s++) {
        double edge = starts[s] * gridFrames;
        sections[s].start = edge;
        if (s == 0) {
            continue;
        }
        double previous = starts[s - 1] * gridFrames;
        double next = s + 1 < count ? starts[s + 1] * gridFrames : total;
        int64_t first = (int64_t)ceil(fmax(edge - 2 * gridFrames, (previous + edge) / 2) / cell);
        int64_t last = (int64_t)floor(fmin(edge + 2 * gridFrames, (edge + next) / 2) / cell);
        NSUInteger cells = last > first ? (NSUInteger)(last - first) : 0;
        levels.resize(cells * wavecore::kBandCount);
        for (NSUInteger i = 0; i < cells; i++) {
            double at = (double)(first + (int64_t)i) * cell;
            wavecore::Column column = waveform->column(at, at + cell);
            for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
                levels[i * wavecore::kBandCount + b] = column.bandLoudest[b] / kBandShareOfFullScale[b];
            }
        }
        NSUInteger split = VibeWaveformSectionSplit(levels.data(), cells);
        if (split > 0) {
            sections[s].start = (double)(first + (int64_t)split) * cell;
        }
    }
    std::vector<double> sums(count * wavecore::kBandCount, 0.0);
    std::vector<NSUInteger> held(count, 0);
    NSUInteger s = 0;
    for (NSUInteger j = 0; j < columns; j++) {
        double center = (j + 0.5) * gridFrames;
        while (s + 1 < count && center >= sections[s + 1].start) {
            s++;
        }
        held[s]++;
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            sums[s * wavecore::kBandCount + b] += grid[j * wavecore::kBandCount + b];
        }
    }
    for (NSUInteger s = 0; s < count; s++) {
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            sections[s].meanSquares[b] = held[s] ? (float)(sums[s * wavecore::kBandCount + b] / held[s]) : 0;
        }
    }
    return sections;
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
    // The fills in the picture's space, kept until the theme or the space
    // changes them.
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
    VibeStepPicture _drawn;
    // Spectrum's color windows and its columns' peaks, kept across fills.
    std::vector<float> _bandMeanSquares;
    std::vector<float> _peaks;
    // The colors are part of the target, so a coloring change refills it.
    BOOL _colorsBySection;
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
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
                       rebuild:^{ [weakSelf rebuildPicture]; }];
        _morph.samplesPerBar = _spectrum ? kSpectrumSamplesPerBar : wavecore::kBandCount;
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
    if (_spectrum && _colorsBySection != self.theme.spectrumColorsBySection) {
        _colorsBySection = self.theme.spectrumColorsBySection;
        [_morph invalidateTarget];
    }
    // The fills are painted into the picture, so new ones redraw it.
    NSArray<VibeColor *> *fills = _spectrum ? self.theme.spectrumColors : self.theme.bandColors;
    if (![_fillColors isEqualToArray:fills]) {
        _fillColors = fills;
        [self convertFills];
        [_morph rebuildNow];
    }
}

- (void)convertFills {
    for (NSUInteger i = 0; i < MIN(_fillColors.count, kLayerCount); i++) {
        VibeFillComponents(_fillColors[i], self.pictureColorSpace, _fills[i]);
    }
}

// The view rebuilds after it sets the space.
- (void)setPictureColorSpace:(CGColorSpaceRef)space {
    [super setPictureColorSpace:space];
    [self convertFills];
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
    // By section's fit is the track's, so both parts of a fill share one.
    __block std::vector<VibeSpectrumSection> sections;
    [self updateStepTargetForSize:bounds.size waveform:waveform columnsPerPixel:columnsPerPixel
                             fill:^(float *out, const wavecore::StepPart &part) {
        [self fillBandLevels:out part:part waveform:waveform sections:sections];
    }];
}

// The bands are read from the summary alone.
- (double)minimumFramesPerPointForWaveform:(AudioWaveform *)waveform {
    return VibeWaveformMinimumFramesPerPoint(waveform->binFrames());
}

// Heights are each band's loudest window. Spectrum's outline is the tallest
// band, shaped by the peaks at deep zoom. Spectrum colors use a window of
// their own (kVibeWaveformSpectrumColorSeconds), never narrower than a
// column each side, and unclamped. By section, each column takes the section
// under its center. sections holds them once the fill's first part finds
// them.
- (void)fillBandLevels:(float *)out part:(const wavecore::StepPart &)part waveform:(AudioWaveform *)waveform
              sections:(std::vector<VibeSpectrumSection> &)sections {
    NSUInteger count = part.count, stride = _morph.samplesPerBar;
    double frames = part.framesPerColumn();
    // Under Normalize each band is measured against its own loudest window,
    // so a hot master's bands fill their ceilings rather than pegging.
    // Otherwise against its share of the fixed full scale. A streaming load
    // takes the louder of the two so far. With the share alone a hot
    // master's bands pegged until the decode completed, and then the whole
    // strip shrank at once.
    BOOL normalize = self.normalizesLevels;
    wavecore::Column track = normalize ? waveform->column(0, (double)waveform->totalFrames()) : wavecore::Column();
    float references[wavecore::kBandCount];
    for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
        float share = kVibeWaveformFullScaleRMS * kBandShareOfFullScale[b];
        float loudest = track.bandLoudest[b];
        references[b] = !(loudest > 0) ? share : waveform->isComplete() ? loudest : fmaxf(loudest, share);
    }
    float gainDB = self.gainDB;
    auto heights = [&](const wavecore::Column &column, float *bands) {
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            bands[b] = kBandCeiling[b] * VibeWaveformBarLevel(column.bandLoudest[b], references[b], gainDB);
        }
    };
    if (_spectrum) {
        _peaks.resize(count);
    }
    for (NSUInteger i = 0; i < count; i++) {
        // A column at a time, never through the detail, whose frames hold no
        // bands.
        double k = (double)(part.first + (int64_t)i);
        wavecore::Column column = waveform->column(k * frames, (k + 1) * frames);
        if (!_spectrum) {
            heights(column, out + i * stride);
            continue;
        }
        float bands[wavecore::kBandCount];
        heights(column, bands);
        out[i * stride] = fmaxf(bands[0], fmaxf(bands[1], bands[2]));
        _peaks[i] = column.extent();
    }
    if (!_spectrum) {
        return;
    }
    double weight = VibeSpectrumPeakShapeWeight(frames / waveform->sampleRate());
    if (weight > 0) {
        [self shapeOutline:out part:part waveform:waveform weight:(float)weight heights:heights];
    }
    _bandMeanSquares.resize(count * wavecore::kBandCount);
    if (self.theme.spectrumColorsBySection && sections.empty()) {
        sections = VibeSpectrumSections(waveform);
    }
    if (self.theme.spectrumColorsBySection && !sections.empty()) {
        // The columns run in order, so the section under each follows on.
        NSUInteger section = 0;
        for (NSUInteger i = 0; i < count; i++) {
            double center = ((double)(part.first + (int64_t)i) + 0.5) * frames;
            while (section + 1 < sections.size() && center >= sections[section + 1].start) {
                section++;
            }
            memcpy(&_bandMeanSquares[i * wavecore::kBandCount], sections[section].meanSquares,
                   sizeof(float) * wavecore::kBandCount);
        }
    } else {
        double halfWidth = fmax(frames, kVibeWaveformSpectrumColorSeconds * waveform->sampleRate());
        waveform->tentBandMeanSquares(frames, part.first, count, halfWidth, _bandMeanSquares.data());
    }
    for (NSUInteger i = 0; i < count; i++) {
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            float meanSquare = fmaxf(_bandMeanSquares[i * wavecore::kBandCount + b], 0);
            out[i * stride + 1 + b] = sqrtf(meanSquare) / kBandShareOfFullScale[b];
        }
    }
}

// A kick's low band builds for 40 to 60 ms after its attack. Each column's
// peak is scaled by the level and the peak within this far of it, so the
// attack stands at the level it builds to.
static const double kPeakShapeReachSeconds = 0.1;

// Spectrum's outline, raised toward its peaks' shape: each column's peak
// scaled so the loudest peak within reach draws the tallest band's level
// there. A window per column, not a grid, so no grid edge can fall inside an
// attack. Never lower than the bands, and never above the level within
// reach, so the quiet columns beside a hit stay quiet. weight fades the
// shape in.
- (void)shapeOutline:(float *)out part:(const wavecore::StepPart &)part waveform:(AudioWaveform *)waveform
              weight:(float)weight heights:(const std::function<void(const wavecore::Column &, float *)> &)heights {
    NSUInteger count = part.count, stride = _morph.samplesPerBar;
    double frames = part.framesPerColumn();
    double reach = kPeakShapeReachSeconds * waveform->sampleRate();
    for (NSUInteger i = 0; i < count; i++) {
        double center = ((double)part.first + i + 0.5) * frames;
        wavecore::Column around = waveform->column(center - reach, center + reach);
        float bands[wavecore::kBandCount];
        heights(around, bands);
        float level = fmaxf(bands[0], fmaxf(bands[1], bands[2]));
        float peak = around.extent();
        float shaped = peak > 0 ? fminf(_peaks[i] / peak, 1) * level : 0;
        float tallest = out[i * stride];
        out[i * stride] = tallest + weight * fmaxf(shaped - tallest, 0);
    }
}

// The morph's rebuild callback. Each pixel column reads the two steps
// linearly between their columns' centers, crossfaded, and paints the sets of
// bands in order; the fill's coverage smooths their tops.
- (void)rebuildPicture {
    const std::vector<float> &displayed = [_morph displayedSamples];
    VibeRenderPixels pixels = _pixels;
    wavecore::StepWindow window = _window;
    NSUInteger stride = _morph.samplesPerBar;
    CGImageRef image = NULL;
    VibeSignpostBegin(waveform_raster);
    if (!displayed.empty() && displayed.size() == window.columnCount() * stride && pixels.width() > 0 &&
        pixels.height > 0) {
        const float *samples = displayed.data();
        double framesPerPixel = [self framesPerPixel];
        const double framesPerColumn[2] = {window.parts[0].framesPerColumn(), window.parts[1].framesPerColumn()};
        CGFloat height = pixels.height;
        CGFloat midY = height / 2, baseline = VibeBarBaseline(height), vscale = VibeBarVScale(height);
        // The hairline holds even after a clear, so a cleared picture collapses
        // onto it. Below it 3-Band's stacked bands blended into stray colors,
        // column by column. An empty view that has settled keeps no samples,
        // so it draws nothing.
        CGFloat minimum = pixels.scale;
        BOOL centered = self.centered, spectrum = _spectrum;
        float fills[kLayerCount][3];
        memcpy(fills, _fills, sizeof(fills));
        VibeStepPicture::Look look = {pixels.height, pixels.scale, _picture.contentsAreFlipped, framesPerPixel,
                                      {window.parts[0].step, window.parts[1].step}, window.coarse};
        look.style[0] = centered;
        look.style[1] = spectrum;
        memcpy(&look.style[2], fills, sizeof(fills));
        // A pixel's bands read between columns, so none stands above the
        // tallest column's, or below the hairline. One pass over every
        // sample: Spectrum's color levels make it a looser bound, and a pass
        // a band at a stride cost 3% of a resize.
        float tallestLevel = 0;
        vDSP_maxv(samples, 1, &tallestLevel, displayed.size());
        CGFloat tallest = MAX(minimum / 2, fminf(fmaxf(tallestLevel, 0), 1) * vscale);
        CGFloat inkLow = centered ? midY - tallest : baseline, inkHigh = centered ? midY + tallest : baseline + 2 * tallest;
        // Seven spans a column cost more than copying it.
        image = _drawn.newImage(look, pixels, window, stride, displayed, (int)floor(height - inkHigh),
                                (int)ceil(height - inkLow), 0.75f, self.pictureColorSpace, !_morph.isSettled,
                                [&](uint32_t *out, ptrdiff_t rowStride, int x0, int x1) {
            wavecore::ColumnPaint column(pixels.height);
            for (int x = x0; x < x1; x++) {
                column.clear();
                float bar[kSpectrumSamplesPerBar] = {};
                double center = (x + 0.5) * framesPerPixel;
                float weights = 0;
                for (int p = 0; p < 2; p++) {
                    float weight = window.weight(p);
                    if (weight > 0 && window.parts[p].count > 0) {
                        wavecore::ColumnPair pair = wavecore::ColumnPairAroundFrame(
                                center, framesPerColumn[p], window.parts[p].first, window.parts[p].count);
                        const float *left = samples + (window.offset(p) + pair.left) * stride;
                        const float *right = samples + (window.offset(p) + pair.right) * stride;
                        for (NSUInteger k = 0; k < stride; k++) {
                            bar[k] += weight * (left[k] + (right[k] - left[k]) * pair.toRight);
                        }
                        weights += weight;
                    }
                }
                if (weights > 0) {
                    for (NSUInteger k = 0; k < stride; k++) bar[k] /= weights;
                }
                CGFloat half[wavecore::kBandCount];
                CGFloat tallest = spectrum ? MAX(clampRange((CGFloat)bar[0], 0, 1) * vscale, minimum / 2)
                                           : VibeThreeBandHalves(bar, vscale, minimum, half);
                if (spectrum) {
                    float rgb[3];
                    VibeSpectrumColor(bar + 1, fills, rgb);
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
                column.write(out + (x - x0), rowStride);
            }
        });
    }
    if (!image) {
        _drawn.clear();
        std::vector<float>().swap(_bandMeanSquares);
        std::vector<float>().swap(_peaks);
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
