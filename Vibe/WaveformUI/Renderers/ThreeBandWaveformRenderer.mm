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

// In the layer order. Dark is the 3-band palette of
// hdelplan/three-band-waveform: blue lows, amber mids, white highs, brown
// where low and mid overlap, pale tints wherever high joins. Light keeps the
// hues and turns the luminance over, since white highs vanish on a light
// window: the highs and their tints go dark, and the amber deepens to hold
// its edge against the background. Fixed rather than themed, because the hue
// is which band.
static CGColorRef VibeThreeBandColor(NSUInteger layer, BOOL isDark) {
    static const uint32_t kRGB[2][kLayerCount] = {
        {0x0055e1, 0xd97706, 0x262626, 0xa35a0c, 0x17306b, 0x5c3a0e, 0x33302c},
        {0x0055e1, 0xffa600, 0xffffff, 0xb4690a, 0xd2dcfa, 0xfff0d7, 0xf5ebd7},
    };
    static CGColorRef colors[2][kLayerCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger dark = 0; dark < 2; dark++) {
            for (NSUInteger i = 0; i < kLayerCount; i++) {
                uint32_t rgb = kRGB[dark][i];
                colors[dark][i] = CGColorCreateSRGB((rgb >> 16 & 0xff) / 255.0, (rgb >> 8 & 0xff) / 255.0,
                                                    (rgb & 0xff) / 255.0, 1);
            }
        }
    });
    return colors[isDark ? 1 : 0][layer];
}

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
// lowest band of its set, appended to the caller's paths, plus the hover
// slice's outline (the tallest band) when one is given. The envelopes nest as
// their sets do, since a set's lowest band is never above a subset's, so the
// painter's order alone colors each height by the bands reaching it, and the
// fill's antialiasing smooths the steps between bars. The live layers and the
// bake both draw from here, which keeps them pixel-identical; points is the
// caller's scratch.
static void VibeAddThreeBandPaths(CGMutablePathRef *paths, CGMutablePathRef outline, std::vector<CGPoint> *points,
                                  CGSize size, const float *samples, NSUInteger count, CGFloat minimumHeight) {
    if (count == 0) {
        return;
    }
    CGFloat midY = size.height / 2;
    CGFloat vscale = VibeBarVScale(size.height);
    CGFloat pitch = size.width / (CGFloat)count;
    // Per band set (by mask; 0 is the outline), one polygon: the left edge,
    // the top through the bars' centers, the right edge, the bottom back.
    NSUInteger stride = 2 * count + 4;
    points->resize(8 * stride);
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat half[kAudioWaveformBandCount];
        CGFloat tallest = VibeThreeBandHalves(samples + i * kAudioWaveformBandCount, vscale, minimumHeight, half);
        CGFloat x = pitch * ((CGFloat)i + 0.5);
        CGFloat lowMid = MIN(half[0], half[1]);
        const CGFloat heights[8] = {tallest, half[0], half[1], lowMid, half[2], MIN(half[0], half[2]),
                                    MIN(half[1], half[2]), MIN(lowMid, half[2])};
        for (NSUInteger mask = outline ? 0 : 1; mask < 8; mask++) {
            CGPoint *polygon = points->data() + mask * stride;
            polygon[1 + i] = CGPointMake(x, midY + heights[mask]);
            polygon[stride - 2 - i] = CGPointMake(x, midY - heights[mask]);
        }
    }
    for (NSUInteger mask = 0; mask < 8; mask++) {
        CGMutablePathRef path = mask ? paths[kLayerForBands[mask]] : outline;
        if (!path) {
            continue;
        }
        CGPoint *polygon = points->data() + mask * stride;
        polygon[0] = CGPointMake(0, polygon[1].y);
        polygon[count + 1] = CGPointMake(size.width, polygon[count].y);
        polygon[count + 2] = CGPointMake(size.width, polygon[count + 3].y);
        polygon[stride - 1] = CGPointMake(0, polygon[stride - 2].y);
        CGPathAddLines(path, NULL, polygon, stride);
        CGPathCloseSubpath(path);
    }
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
    // through the inner ones.
    CALayer *_bands;
    CAShapeLayer *_bandLayers[kLayerCount];
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
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer] = VibePinned([CAShapeLayer layer], scale);
        [_bands addSublayer:_bandLayers[layer]];
    }
    _sides = VibePinned([CALayer layer], scale);
    _playedSide = VibePinned([CAGradientLayer layer], scale);
    _unplayedSide = VibePinned([CAGradientLayer layer], scale);
    for (CAGradientLayer *side in @[_playedSide, _unplayedSide]) {
        VibeAimBarGradient(side);
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

// The palette follows only the appearance; the theme gives the ramp, or none,
// and the hover slice, an affordance rather than a band.
- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer].fillColor = VibeThreeBandColor(layer, isDark);
    }
    _playedSide.colors = VibeThreeBandSideColors(1, self.theme.flatFill);
    _unplayedSide.colors = VibeThreeBandSideColors(kUnplayedOpacity, self.theme.flatFill);
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
    [CATransaction commit];
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
    if (wasHidden && !_hoverHost.hidden) {
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
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];
    [self setHoverHighlightX:self.hoverHighlightX];

    NSUInteger count = [self barCountForWidth:bounds.size.width];
    [_morph updateTargetForSize:bounds.size identity:waveform count:count * kAudioWaveformBandCount
                           fill:^(std::vector<float> &target) {
        [self fillBandLevels:target.data() count:count waveform:waveform];
    }];
}

// Each bar's levels are its own window's (barCountForWidth:), smoothed so a
// resize does not ripple them. The mean squares land in out first, so
// Normalize reads them where the bars are its columns. Normalize and Gain
// apply to all three bands alike.
- (void)fillBandLevels:(float *)out count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    waveform->getSmoothedMeanSquares(count, NULL, out);
    float fullScaleRMS = [self bandFullScaleRMSForWaveform:waveform count:count meanSquares:out];
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count * kAudioWaveformBandCount; i++) {
        out[i] = VibeWaveformBarLevel(out[i], fullScaleRMS * kBandShareOfFullScale[i % kAudioWaveformBandCount],
                                      gainDB);
    }
}

// Normalize's reference is the loudest band against its share, so the tallest
// band at the track's loudest column draws at full height: the full mix's
// reference left every band short of it. It keeps
// VibeWaveformFullScaleRMSForWaveform's rules — the whole track, the 1,024
// columns, the fixed ceiling — but is its own so that within the columns it
// reads the mean squares the fill just smoothed: measuring them through the
// waveform again cost a fifth of every resize frame's instructions. Past the
// columns it measures them under the same window, so the reference does not
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
        waveform->getSmoothedMeanSquares(count, NULL, columns.data());
        drawn = columns.data();
    }
    float maxima[kAudioWaveformBandCount] = {};
    for (NSUInteger i = 0; i < count * kAudioWaveformBandCount; i++) {
        maxima[i % kAudioWaveformBandCount] = fmaxf(maxima[i % kAudioWaveformBandCount], drawn[i]);
    }
    float loudest = 0;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        loudest = fmaxf(loudest, sqrtf(maxima[b]) / kBandShareOfFullScale[b]);
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
    CGMutablePathRef paths[kLayerCount];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        paths[layer] = CGPathCreateMutable();
    }
    // setHoverHighlightX: rebuilds as the slice appears.
    CGMutablePathRef outline = _hoverHost.hidden ? NULL : CGPathCreateMutable();
    VibeAddThreeBandPaths(paths, outline, &_points, _morph.size, samples.data(), count, _morph.barMinHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        _bandLayers[layer].path = paths[layer];
        CGPathRelease(paths[layer]);
    }
    if (outline) {
        _hoverMask.path = outline;
        CGPathRelease(outline);
    }
    [CATransaction commit];
    VibeSignpostEnd(waveform_path);
}

#pragma mark - Envelope bitmap

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
    CGMutablePathRef paths[kLayerCount];
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        paths[layer] = CGPathCreateMutable();
    }
    std::vector<CGPoint> points;
    VibeAddThreeBandPaths(paths, NULL, &points, size, (const float *)samples.bytes, count, 1);
    for (NSUInteger layer = 0; layer < kLayerCount; layer++) {
        if (!CGPathIsEmpty(paths[layer])) {
            CGContextAddPath(ctx, paths[layer]);
            CGContextSetFillColorWithColor(ctx, VibeThreeBandColor(layer, self.isDark));
            CGContextFillPath(ctx);
        }
        CGPathRelease(paths[layer]);
    }
    if (!self.theme.flatFill) {
        // The played side's mask, so the bake matches the live layers.
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
        VibeFillBarGradient(ctx, size, VibeThreeBandSideColors(1, NO));
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
