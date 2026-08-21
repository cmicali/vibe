//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "PlatformTypes.h"
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

// This family's resting levels live in the theme colors' own alpha
// (WaveformTheme.h) — the White pair carries what used to be this file's
// kWaveformOpacity — so the renderer owns only the ramp SHAPE below, scaled
// relative to each color's level through VibeColorAtRampFraction. The
// envelope bitmap bakes the same stops, so the two cannot drift.

@implementation DetailedAudioWaveformRenderer {
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

    // The samples are a normalized, interleaved min and max per bar, and
    // rebuildMaskPaths is the rebuild callback.
    WaveformMorphEngine *_morph;
}

+ (NSString *)styleIdentifier {
    return @"detailed";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_DETAILED;
}

- (NSUInteger)numBars {
    return 1024;
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return width / (CGFloat)count;
}

- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth {
    return barWidth * (CGFloat)index;
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
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
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
    _barMask.fillColor = [VibeColor whiteColor].CGColor;
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

- (void)setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<VibeColor*>*)colors {
    NSMutableArray *cgColors = [[NSMutableArray alloc] initWithCapacity:colors.count];
    for (VibeColor *color in colors) {
        [cgColors addObject:(id)color.CGColor];
    }
    layer.colors = cgColors;
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    [self setGradientLayerColors:_playedGradient colors:[self gradientColorsForColor:self.theme.playedColor isDark:isDark]];
    [self setGradientLayerColors:_unplayedGradient colors:[self gradientColorsForColor:self.theme.unplayedColor isDark:isDark]];
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
    const CGFloat kBottomAlpha = 0.45;
    return @[
            color,
            VibeColorAtRampFraction(color, kBottomAlpha),
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
    // Snap both edges to the device-pixel grid. A fractional origin or width
    // leaves half-lit edge pixels, and the column is supposed to be the
    // brightest thing in the waveform.
    CGFloat scale = VibeBackingScaleForLayer(self.parentLayer);
    CGFloat width = MAX(round(kHoverHighlightWidth * scale), 1) / scale;
    CGFloat left = floor((x - width / 2) * scale) / scale;
    left = MIN(MAX(left, 0), MAX(0, b.size.width - width));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _hoverColumn.bounds = CGRectMake(0, 0, width, b.size.height);
    _hoverColumn.position = CGPointMake(left, 0);
    _hoverColumn.hidden = NO;
    [CATransaction commit];
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    if (!_playedClip || !self.parentLayer) return;
    CGRect b = self.parentLayer.bounds;
    CGFloat w = b.size.width * progress;
    if (w < 0) w = 0;
    if (w > b.size.width) w = b.size.width;
    _playedClip.bounds = CGRectMake(0, 0, w, b.size.height);
    _playedClip.position = CGPointZero;
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
    // variants. Do not clamp.
    NSUInteger count = self.numBars;

    // The target the bars ease toward: the waveform's per-bar min and max, or
    // all-zero, collapsed to the midline, when there is no waveform. A track
    // change therefore morphs the old bars toward zero until the new track's
    // waveform arrives and retargets them to its shape. The engine owns the
    // fast, collapsed and commit scaffold and skips this fill on a live-resize
    // frame, where the waveform identity and count are unchanged. Only the
    // sampling itself belongs to this family.
    [_morph updateTargetForSize:bounds.size identity:waveform count:count * 2
                           fill:^(std::vector<float> &target) {
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
            target[i * 2] = m.getMin();
            target[i * 2 + 1] = m.getMax();
        }
    }];
}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {
    [_morph dipDisplayedSamplesFromFraction:from toFraction:to];
}

- (void)settleMorphImmediately {
    [_morph settleImmediately];
}

- (void)backingScaleDidChange {
    [_morph rebuildNow];
    // Re-snap the hover column to the new device-pixel grid.
    [self setHoverHighlightX:self.hoverHighlightX];
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
    CGSize maskSize = _morph.size;
    CGFloat width = maskSize.width;
    CGFloat midY = maskSize.height / 2;
    CGFloat vscale = VibeBarVScale(maskSize.height);
    CGFloat barWidth = [self barWidthForWidth:width barCount:count];
    // Hairline floor vs. collapse-to-nothing — policy on the engine, shared
    // with the Sonic Cirrus family.
    CGFloat minHeight = _morph.barMinHeight;
    BOOL settled = _morph.isSettled;
    CGFloat scale = VibeBackingScaleForLayer(self.parentLayer);
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        // y-up layer coords: the bar's top comes from the positive peak (max),
        // the bottom from the negative peak (min). Subtracting instead draws
        // the envelope vertically mirrored (visible on DC-offset material).
        CGFloat top = midY + samples[i * 2 + 1] * vscale;
        CGFloat bottom = midY + samples[i * 2] * vscale;
        if (settled) {
            top = round(top * scale) / scale;
            bottom = round(bottom * scale) / scale;
        }
        CGFloat height = MAX(top - bottom, minHeight);
        CGFloat x = [self barXForIndex:i width:width barCount:count barWidth:barWidth];
        CGPathAddRect(path, NULL, CGRectMake(x, bottom, barWidth, height));
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _barMask.path = path;
    [CATransaction commit];
    CGPathRelease(path);
    VibeSignpostEnd(waveform_path);
}

#pragma mark - Envelope bitmap

- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform {
    NSUInteger count = self.numBars;
    NSMutableData *data = [NSMutableData dataWithLength:count * 2 * sizeof(float)];
    float *out = (float *)data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        out[i * 2] = m.getMin();
        out[i * 2 + 1] = m.getMax();
    }
    return data;
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientColorsForColor:self.theme.playedColor isDark:self.isDark]];
}

- (CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return [self newEnvelopeImageForSize:size scale:scale samples:samples
                                   stops:[self gradientColorsForColor:self.theme.unplayedColor isDark:self.isDark]];
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples
                                stops:(NSArray<VibeColor *> *)stops {
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

    // rebuildMaskPaths' settled branch: pixel-rounded bar edges and the
    // 1-point hairline floor a loaded waveform draws with.
    const float *s = (const float *)samples.bytes;
    CGFloat midY = size.height / 2;
    CGFloat vscale = VibeBarVScale(size.height);
    CGFloat barWidth = [self barWidthForWidth:size.width barCount:count];
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat top = round((midY + s[i * 2 + 1] * vscale) * scale) / scale;
        CGFloat bottom = round((midY + s[i * 2] * vscale) * scale) / scale;
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = [self barXForIndex:i width:size.width barCount:count barWidth:barWidth];
        CGPathAddRect(path, NULL, CGRectMake(x, bottom, barWidth, height));
    }
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGPathRelease(path);

    // configureGradient:'s band-pinned fade. This family's fade only — Basic
    // re-aims its gradient, so its styles would need their own bake. The
    // stops are the caller's theme-derived ramp, resting levels already in
    // their alphas, same as the live layers': the two must stay
    // pixel-identical.
    NSMutableArray *cgColors = [[NSMutableArray alloc] initWithCapacity:stops.count];
    for (VibeColor *color in stops) {
        [cgColors addObject:(__bridge id)color.CGColor];
    }
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cgColors, NULL);
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

@end
