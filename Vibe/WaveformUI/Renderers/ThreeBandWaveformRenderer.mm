//
//  ThreeBandWaveformRenderer.mm
//  Vibe
//

#import "ThreeBandWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "WaveformZoomMath.h"

#include <algorithm>
#include <vector>
#include <cmath>

// Each band's height tops out at its ceiling: the lows the whole band, the
// mids three quarters, the highs half. So the bands nest as a DJ's waveform
// does, the lows outside, and the highs show as each hit's tip.
static const float kBandCeiling[wavecore::kBandCount] = {1.0f, 0.75f, 0.5f};

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
// halfway to a neighbor's. The peaks then put it on the hit itself
// (VibeWaveformSectionSnapToHit). A section is colored by the mean of the
// grid columns whose centers it holds. The grid spans the length a streaming
// load will reach, so a delivery never moves a column.
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
    NSUInteger count = VibeWaveformSectionStarts(grid.data(), columns, kVibeWaveformBandShares, starts);
    sections.resize(count);
    double cell = waveform->binFrames();
    // A kick's build, in cells: how far an edge may move onto its hit.
    int64_t reach = std::max((int64_t)1, (int64_t)ceil(0.1 * waveform->sampleRate() / cell));
    std::vector<wavecore::Column> read;
    std::vector<float> levels, peaks;
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
        read.resize(cells);
        levels.resize(cells * wavecore::kBandCount);
        peaks.resize(cells);
        waveform->columns(cell, first, cells, read.data());
        for (NSUInteger i = 0; i < cells; i++) {
            for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
                levels[i * wavecore::kBandCount + b] = read[i].bandLoudest[b] / kVibeWaveformBandShares[b];
            }
            peaks[i] = read[i].extent();
        }
        NSUInteger split = VibeWaveformSectionSplit(levels.data(), cells);
        if (split == 0) {
            continue;
        }
        // The peaks a reach either side of the split place it on the hit.
        NSUInteger from = split > (NSUInteger)reach ? split - (NSUInteger)reach : 0;
        NSUInteger to = MIN(cells, split + (NSUInteger)reach);
        split = from + VibeWaveformSectionSnapToHit(peaks.data() + from, to - from, split - from);
        sections[s].start = (double)(first + (int64_t)split) * cell;
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

// The section a column of frames [first, last) is colored by: the one under
// its center, unless an edge falls inside the column. Such a column is as tall
// as the loudest peak on either side, so it takes the side that holds that
// peak. By its center alone, a kick's first column drew tall in the color
// before it. under follows the centers, so columns are passed in order.
static NSUInteger VibeSectionOfColumn(const std::vector<VibeSpectrumSection> &sections, NSUInteger &under,
                                      double first, double last, AudioWaveform *waveform) {
    double center = (first + last) / 2;
    while (under + 1 < sections.size() && center >= sections[under + 1].start) {
        under++;
    }
    // The sections either side of an edge inside the column, if there is one.
    NSUInteger before = under, after = under;
    if (under + 1 < sections.size() && sections[under + 1].start < last) {
        after = under + 1;
    } else if (under > 0 && sections[under].start > first) {
        before = under - 1;
    } else {
        return under;
    }
    double edge = sections[after].start;
    float left = waveform->column(first, edge).extent(), right = waveform->column(edge, last).extent();
    return left == right ? under : left > right ? before : after;
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
    // The colors are part of the target, so a coloring change refills it.
    BOOL _colorsBySection;
}

+ (NSString *)styleIdentifier {
    return @"three_band";
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
    // a pixel for Spectrum, whose colors change from pixel to pixel. As the
    // peak shape fades in, 3-Band moves to a column a pixel too. A column a
    // point is three pixels at 3x, and read between its neighbors' centers
    // each attack rose over them.
    // The peak shape's weight is by the pixel, so both styles fade it in at
    // the same zoom. By the column, 3-Band's wider columns took half of it.
    double pixels = bounds.size.width * _pixels.scale;
    float peakShape = waveform && pixels > 0
            ? (float)VibeWaveformPeakShapeWeight((double)waveform->totalFrames() / waveform->sampleRate() / pixels)
            : 0;
    double columnsPerPixel = _spectrum ? 1 : 1 / _pixels.scale + peakShape * (1 - 1 / _pixels.scale);
    // By section's fit is the track's, so both parts of a fill share one.
    __block std::vector<VibeSpectrumSection> sections;
    [self updateStepTargetForSize:bounds.size waveform:waveform columnsPerPixel:columnsPerPixel
                             fill:^(float *out, const wavecore::StepPart &part) {
        [self fillBandLevels:out part:part waveform:waveform peakShape:peakShape sections:sections];
    }];
}

// The bands are read from the summary alone.
- (double)minimumFramesPerPointForWaveform:(AudioWaveform *)waveform {
    return VibeWaveformMinimumFramesPerPoint(waveform->binFrames());
}

// A kick's low band builds for 40 to 60 ms after its attack. Each column's
// peak is scaled by the level and the peak this far ahead of it, so the
// attack stands at the level it builds to.
static const double kPeakShapeReachSeconds = 0.06;

// Heights are each band's loudest window, shaped by the peaks at deep zoom by
// peakShape's weight. Spectrum's outline is the tallest band. Spectrum colors use a window of
// their own (kVibeWaveformSpectrumColorSeconds), never narrower than a
// column each side, unclamped and kept inside the column's section. By
// section, each column takes the section under its center. sections holds
// them once the fill's first part finds them.
- (void)fillBandLevels:(float *)out part:(const wavecore::StepPart &)part waveform:(AudioWaveform *)waveform
             peakShape:(float)peakShape sections:(std::vector<VibeSpectrumSection> &)sections {
    NSUInteger count = part.count, stride = _morph.samplesPerBar;
    double frames = part.framesPerColumn();
    // Under Normalize each band is measured against its own loudest window,
    // raised or lowered, so a hot master's bands fill their ceilings rather
    // than pegging. Otherwise against its share of the fixed full scale.
    wavecore::Column track = VibeWaveformNormalizeColumn(waveform, self.normalizesLevels);
    float references[wavecore::kBandCount];
    for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
        references[b] = VibeWaveformReference(track.bandLoudest[b], kVibeWaveformFullScaleRMS * kVibeWaveformBandShares[b],
                                              waveform->isComplete());
    }
    float gainDB = self.gainDB;
    BOOL spectrum = _spectrum;
    NSUInteger heightCount = spectrum ? 1 : wavecore::kBandCount;
    auto heights = [&](const wavecore::Column &column, float *into) {
        float bands[wavecore::kBandCount];
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            bands[b] = kBandCeiling[b] * VibeWaveformBarLevel(column.bandLoudest[b], references[b], gainDB);
        }
        if (spectrum) {
            into[0] = fmaxf(bands[0], fmaxf(bands[1], bands[2]));
        } else {
            memcpy(into, bands, sizeof(bands));
        }
    };
    double reach = kPeakShapeReachSeconds * waveform->sampleRate();
    for (NSUInteger i = 0; i < count; i++) {
        // A column at a time, never through the detail, whose frames hold no
        // bands.
        double k = (double)(part.first + (int64_t)i);
        wavecore::Column column = waveform->column(k * frames, (k + 1) * frames);
        float *height = out + i * stride;
        heights(column, height);
        if (peakShape > 0) {
            // Raised toward the peaks' shape: the column's peak scaled so the
            // loudest peak just ahead draws the level there. Only ahead: a
            // window behind as well raised a kick's body to the hi-hat after
            // it, and its tail to its plateau. Never lowered, and never above
            // the level ahead, so the quiet columns before a hit stay quiet.
            wavecore::Column ahead = waveform->column(k * frames, (k + 0.5) * frames + reach);
            float levels[wavecore::kBandCount];
            heights(ahead, levels);
            float share = ahead.extent() > 0 ? fminf(column.extent() / ahead.extent(), 1) : 0;
            for (NSUInteger h = 0; h < heightCount; h++) {
                height[h] += peakShape * fmaxf(share * levels[h] - height[h], 0);
            }
        }
    }
    if (!spectrum) {
        return;
    }
    _bandMeanSquares.resize(count * wavecore::kBandCount);
    if (sections.empty()) {
        sections = VibeSpectrumSections(waveform);
    }
    if (self.theme.spectrumColorsBySection && !sections.empty()) {
        NSUInteger under = 0;
        for (NSUInteger i = 0; i < count; i++) {
            double k = (double)(part.first + (int64_t)i);
            NSUInteger section = VibeSectionOfColumn(sections, under, k * frames, (k + 1) * frames, waveform);
            memcpy(&_bandMeanSquares[i * wavecore::kBandCount], sections[section].meanSquares,
                   sizeof(float) * wavecore::kBandCount);
        }
    } else {
        double halfWidth = fmax(frames, kVibeWaveformSpectrumColorSeconds * waveform->sampleRate());
        waveform->tentBandMeanSquares(frames, part.first, count, halfWidth, _bandMeanSquares.data());
        [self keepTents:part.first count:count framesPerColumn:frames halfWidth:halfWidth
             inSections:sections waveform:waveform];
    }
    for (NSUInteger i = 0; i < count; i++) {
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            float meanSquare = fmaxf(_bandMeanSquares[i * wavecore::kBandCount + b], 0);
            out[i * stride + 1 + b] = sqrtf(meanSquare) / kVibeWaveformBandShares[b];
        }
    }
}

// Precise's tents stop at the section edges, as By section's colors do. A
// tent that would cross one is moved inside its column's section
// (VibeSectionOfColumn), whole, or narrowed to a section shorter than it. Crossing, it colored the two seconds before a
// kick came back by the kick. The columns a moved tent covers share one, so
// each is read once.
- (void)keepTents:(int64_t)first count:(NSUInteger)count framesPerColumn:(double)frames halfWidth:(double)halfWidth
       inSections:(const std::vector<VibeSpectrumSection> &)sections waveform:(AudioWaveform *)waveform {
    double total = (double)waveform->totalFrames();
    NSUInteger under = 0;
    double readCenter = -1, readWidth = -1;
    float read[wavecore::kBandCount] = {};
    for (NSUInteger i = 0; i < count && !sections.empty(); i++) {
        double k = (double)(first + (int64_t)i), center = (k + 0.5) * frames;
        NSUInteger section = VibeSectionOfColumn(sections, under, k * frames, (k + 1) * frames, waveform);
        double start = sections[section].start;
        double end = section + 1 < sections.size() ? sections[section + 1].start : total;
        double width = fmax(frames, fmin(halfWidth, (end - start) / 2));
        double inside = clampRange(center, start + width, fmax(start + width, end - width));
        if (inside == center && width == halfWidth) {
            continue;
        }
        if (inside != readCenter || width != readWidth) {
            // One column whose center is inside: column 0 of a grid twice as wide.
            waveform->tentBandMeanSquares(2 * inside, 0, 1, width, read);
            readCenter = inside;
            readWidth = width;
        }
        memcpy(&_bandMeanSquares[i * wavecore::kBandCount], read, sizeof(read));
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
                        // Spectrum's colors come from the column that gives
                        // the pixel more of its height. Read between the two,
                        // the pixel rising into a kick took the color before
                        // it.
                        const float *colors = left[0] * (1 - pair.toRight) >= right[0] * pair.toRight ? left : right;
                        for (NSUInteger k = 0; k < stride; k++) {
                            float level = spectrum && k > 0 ? colors[k] : left[k] + (right[k] - left[k]) * pair.toRight;
                            bar[k] += weight * level;
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

+ (VibeWaveformPaletteKind)paletteKind {
    return VibeWaveformPaletteKindSpectrum;
}

@end
