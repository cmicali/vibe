//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"
#import "WaveformMorphEngine.h"

#include <vector>
#include <cmath>

// Bars reach at most ±kBarAmplitude·(height/2) from the vertical midline.
// VibeBarVScale is the ONE normalized→pixels scale, shared by the seek hit
// band (seekHitBandForBounds:), the morph engine's frame-skip heuristic (the
// vscale block handed to it in init), the drawn mask (rebuildMaskPaths), and
// the gradient band (configureGradient:) — they silently disagree if any
// site re-derives it.
static const CGFloat kBarAmplitude = 0.75;
static inline CGFloat VibeBarVScale(CGFloat height) {
    return (height / 2) * kBarAmplitude;
}

@implementation DetailedAudioWaveformRenderer {
    NSColor *_gradientColor;

    // One bar-shaped mask clips the whole gradient stack. Masking the two
    // gradients separately would rasterize the identical bar path twice per
    // morph frame — a full-view alpha pass each — and ship the 4096-element
    // path to the render server twice.
    CALayer *_waveformContainer;      // mask: _barMask; holds both gradients
    CAShapeLayer *_barMask;
    CAGradientLayer *_unplayedGradient;

    // Container layer with masksToBounds=YES. Its bounds.size.width is the
    // progress indicator — anything inside is clipped to the played region.
    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;

    // Samples: interleaved min/max per bar, normalized. Rebuild callback:
    // rebuildMaskPaths.
    WaveformMorphEngine *_morph;
}

+ (NSString *)displayName {
    return @"Detailed";
}

- (NSUInteger)numLayers {
    return 1024;
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return width / (CGFloat)count;
}

- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth {
    return barWidth * (CGFloat)index;
}

// Matches the drawn band: bars reach at most ±kBarAmplitude·(height/2) from
// the midline (VibeBarVScale).
- (NSRect)seekHitBandForBounds:(NSRect)bounds {
    CGFloat midY = bounds.size.height / 2;
    CGFloat vscale = VibeBarVScale(bounds.size.height);
    CGFloat bottomY = round(midY - vscale);
    CGFloat topY = round(midY + vscale);
    return NSMakeRect(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return VibeBarVScale(height); }
                       rebuild:^{ [weakSelf rebuildMaskPaths]; }];
        [self setupGradientLayers];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)setupGradientLayers {
    // Overall opacity multiplier applied to both gradient layers — tones the
    // whole waveform down so it sits comfortably over the album-art backdrop.
    const float kWaveformOpacity = 0.75f;

    CGFloat scale = self.parentLayer.contentsScale;

    // Everything composites inside one container that the bar mask clips:
    // unplayed gradient across the full width, played gradient above it
    // revealed by the progress clip. Mask path updates always happen inside
    // setDisableActions:YES transactions — every visible morph is the
    // timer-driven rebuild in rebuildMaskPaths, never a Core Animation path
    // interpolation.
    _waveformContainer = [CALayer layer];
    _waveformContainer.anchorPoint = CGPointZero;
    _waveformContainer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
    _waveformContainer.contentsScale = scale;
    _barMask = [CAShapeLayer layer];
    _barMask.fillColor = [NSColor whiteColor].CGColor;
    _barMask.contentsScale = scale;
    _waveformContainer.mask = _barMask;
    [self.parentLayer addSublayer:_waveformContainer];

    // Unplayed: dim gradient over the full waveform.
    _unplayedGradient = [CAGradientLayer layer];
    _unplayedGradient.opacity = kWaveformOpacity;
    _unplayedGradient.contentsScale = scale;
    [self configureGradient:_unplayedGradient];
    [_waveformContainer addSublayer:_unplayedGradient];

    // Played: bright gradient inside a clip container; resize the container
    // on progress changes to reveal/hide the played portion. Sits on top of
    // the unplayed gradient so its brighter colors win wherever it's visible.
    _playedClip = [CALayer layer];
    _playedClip.masksToBounds = YES;
    _playedClip.anchorPoint = CGPointZero;
    _playedClip.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
    _playedClip.contentsScale = scale;

    _playedGradient = [CAGradientLayer layer];
    _playedGradient.opacity = kWaveformOpacity;
    _playedGradient.contentsScale = scale;
    [self configureGradient:_playedGradient];
    [_playedClip addSublayer:_playedGradient];
    [_waveformContainer addSublayer:_playedClip];
}

- (void)configureGradient:(CAGradientLayer *)gradient {
    // Fade runs top → bottom (layer coords: y=1 is the top, y=0 the bottom),
    // so colors[0] is the top color and colors[last] the bottom. The start/end
    // points are pinned to the waveform's vertical band, not the full view, so
    // the full 100%→70% range lands across the visible bars: bars reach at
    // most ±kBarAmplitude·(height/2) from the midline (VibeBarVScale), i.e.
    // the band spans y ∈ [(1∓kBarAmplitude)/2] — computed, so an amplitude
    // change re-aims the fade automatically. Mapping the fade to the whole
    // view instead would swing the bars only ~0.96→0.74 — too subtle to read.
    gradient.startPoint = CGPointMake(0.5, (1 + kBarAmplitude) / 2);
    gradient.endPoint = CGPointMake(0.5, (1 - kBarAmplitude) / 2);
}

- (void)dealloc {
    [_waveformContainer removeFromSuperlayer];
}

- (void)setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<NSColor*>*)colors {
    NSMutableArray *cgColors = [[NSMutableArray alloc] initWithCapacity:colors.count];
    for (NSColor *color in colors) {
        [cgColors addObject:(id)color.CGColor];
    }
    layer.colors = cgColors;
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    _gradientColor = isDark ? [NSColor whiteColor] : [NSColor blackColor];
    [self setGradientLayerColors:_playedGradient colors:[self playedGradientColors:_gradientColor isDark:isDark]];
    [self setGradientLayerColors:_unplayedGradient colors:[self unplayedGradientColors:_gradientColor isDark:isDark]];
}

// Slight vertical fade: full color at the top, kBottomAlpha of it at the
// bottom (same colors + start/end points in light and dark — the direction
// is fixed by the gradient's startPoint/endPoint, not by the array order).
// Played is fully opaque at the top; unplayed is half as opaque, so the
// played region reads clearly brighter where the two meet at the boundary.
- (NSArray<NSColor *> *)playedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark {
    const CGFloat kBottomAlpha = 0.45;
    const CGFloat kPlayedTop = 1.0;
    return @[
            [baseColor colorWithAlphaComponent:kPlayedTop],
            [baseColor colorWithAlphaComponent:kPlayedTop * kBottomAlpha],
    ];
}

- (NSArray<NSColor *> *)unplayedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark {
    const CGFloat kBottomAlpha = 0.45;
    const CGFloat kUnplayedTop = 0.5;
    return @[
            [baseColor colorWithAlphaComponent:kUnplayedTop],
            [baseColor colorWithAlphaComponent:kUnplayedTop * kBottomAlpha],
    ];
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

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    // Disabled actions: an animated window resize redraws every frame, and
    // implicit 0.25s animations on these leave the waveform chasing the
    // window. (_playedClip needs no wrapper — its actions dict already
    // disables bounds/position.)
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _waveformContainer.frame = localBounds;
    _barMask.frame = localBounds;
    _unplayedGradient.frame = localBounds;
    _playedGradient.frame = localBounds;
    [CATransaction commit];
    [self updateProgress:progress waveform:waveform];

    // The x2/x4/x8 styles intentionally draw more rects than device pixels:
    // the sub-pixel overlap accumulates differently per density, which is
    // what visually distinguishes the oversampling variants. Don't clamp.
    NSUInteger count = self.numLayers;

    // The target the bars ease toward: the waveform's per-bar min/max, or
    // all-zero (collapsed to the midline) when there is no waveform — a
    // track change morphs the old bars toward zero until the new track's
    // waveform arrives and retargets them to its shape.
    std::vector<float> &target = [_morph targetScratchWithCount:count * 2];
    if (waveform) {
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
            target[i * 2] = m.getMin();
            target[i * 2 + 1] = m.getMax();
        }
    }
    else {
        std::fill(target.begin(), target.end(), 0.0f);
    }
    [_morph commitTargetForSize:bounds.size hasWaveform:(waveform != nil)];
}

// Build the bar path for the currently displayed samples and set it on the
// shared mask (the morph engine's rebuild callback). Pixel-rounding is
// reserved for the settled state — mid-morph it would quantize the motion
// into visible 1px steps.
- (void)rebuildMaskPaths {
    const std::vector<float> &samples = [_morph displayedSamples];
    NSUInteger count = samples.size() / 2;
    if (count == 0) {
        return;
    }
    CGSize maskSize = _morph.size;
    CGFloat width = maskSize.width;
    CGFloat midY = maskSize.height / 2;
    CGFloat vscale = VibeBarVScale(maskSize.height);
    CGFloat barWidth = [self barWidthForWidth:width barCount:count];
    // With no waveform, bars are allowed to shrink to nothing; with one,
    // they keep the 1px floor (silent and not-yet-loaded chunks draw as a
    // hairline, matching the settled look mid-load).
    CGFloat minHeight = _morph.hasWaveform ? 1 : 0;
    BOOL settled = _morph.isSettled;
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        // y-up layer coords: the bar's top comes from the positive peak (max),
        // the bottom from the negative peak (min). Subtracting instead draws
        // the envelope vertically mirrored (visible on DC-offset material).
        CGFloat top = midY + samples[i * 2 + 1] * vscale;
        CGFloat bottom = midY + samples[i * 2] * vscale;
        if (settled) {
            top = round(top);
            bottom = round(bottom);
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
}

@end
