//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"

#include <vector>

@implementation DetailedAudioWaveformRenderer {
    NSColor *_gradientColor;

    CAGradientLayer *_unplayedGradient;
    CAShapeLayer *_unplayedMask;

    // Container layer with masksToBounds=YES. Its bounds.size.width is the
    // progress indicator — anything inside is clipped to the played region.
    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;
    CAShapeLayer *_playedMask;

    BOOL _hasHydrated;  // tracks whether the grow-from-midline animation has played for the current waveform

    // Inputs behind the current mask paths, used to skip no-op rebuilds:
    // the per-bar min/max values sampled from the waveform plus the bounds
    // they were laid out in. _maskValid is NO until the first build and
    // after the waveform is cleared.
    std::vector<float> _maskSamples;  // interleaved min/max per bar
    CGSize _maskSize;
    BOOL _maskValid;
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

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
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

    // Unplayed: dim gradient over the full waveform, clipped to bar shape.
    // Path updates happen inside setDisableActions:YES transactions in
    // updateWaveform: — the visible "hydrate" effect comes from the
    // grow-from-midline transform animation there, not from implicit
    // path animations.
    _unplayedGradient = [CAGradientLayer layer];
    _unplayedGradient.opacity = kWaveformOpacity;
    _unplayedGradient.contentsScale = scale;
    [self configureGradient:_unplayedGradient];
    _unplayedMask = [CAShapeLayer layer];
    _unplayedMask.fillColor = [NSColor whiteColor].CGColor;
    _unplayedMask.contentsScale = scale;
    _unplayedGradient.mask = _unplayedMask;
    [self.parentLayer addSublayer:_unplayedGradient];

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
    _playedMask = [CAShapeLayer layer];
    _playedMask.fillColor = [NSColor whiteColor].CGColor;
    _playedMask.contentsScale = scale;
    _playedGradient.mask = _playedMask;
    [_playedClip addSublayer:_playedGradient];
    [self.parentLayer addSublayer:_playedClip];
}

- (void)configureGradient:(CAGradientLayer *)gradient {
    // Fade runs top → bottom (layer coords: y=1 is the top, y=0 the bottom),
    // so colors[0] is the top color and colors[last] the bottom. The start/end
    // points are pinned to the waveform's vertical band, not the full view, so
    // the full 100%→70% range lands across the visible bars: bars reach at most
    // ±0.75·(height/2) from the midline (see vscale in updateWaveform:), i.e.
    // the band spans y ∈ [0.125, 0.875]. Mapping the fade to the whole view
    // instead only swung the bars ~0.96→0.74 — too subtle to read.
    gradient.startPoint = CGPointMake(0.5, 0.875);
    gradient.endPoint = CGPointMake(0.5, 0.125);
}

- (void)dealloc {
    [_unplayedGradient removeFromSuperlayer];
    [_playedClip removeFromSuperlayer];
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
    // Set bounds + position rather than frame on the gradient layers, because
    // when those layers have a non-identity transform (during/after the
    // hydration animation), the frame setter inverts the transform into the
    // bounds — which would 1000× the layer height and put it off-screen.
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CGPoint center = CGPointMake(NSMidX(bounds), NSMidY(bounds));
    _unplayedGradient.bounds = localBounds;
    _unplayedGradient.position = center;
    _playedGradient.bounds = localBounds;
    _playedGradient.position = center;
    // Masks live in the gradient's coordinate space and have no transform,
    // so setting frame is safe and convenient.
    _unplayedMask.frame = localBounds;
    _playedMask.frame = localBounds;
    [self updateProgress:progress waveform:waveform];

    if (!waveform) {
        // Collapse the gradient layers to a thin line at the midline and
        // clear the paths. The next non-nil call animates back to identity.
        _hasHydrated = NO;
        _maskValid = NO;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _unplayedGradient.transform = CATransform3DMakeScale(1, 0.001, 1);
        _playedGradient.transform = CATransform3DMakeScale(1, 0.001, 1);
        _unplayedMask.path = NULL;
        _playedMask.path = NULL;
        [CATransaction commit];
        return;
    }

    CGFloat width = bounds.size.width;
    CGFloat vscale = (bounds.size.height / 2) * 0.75;
    CGFloat midY = bounds.size.height / 2;

    // The x2/x4/x8 styles intentionally draw more rects than device pixels:
    // the sub-pixel overlap accumulates differently per density, which is
    // what visually distinguishes the oversampling variants. Don't clamp.
    NSUInteger count = self.numLayers;
    CGFloat barWidth = [self barWidthForWidth:width barCount:count];

    // Sample the waveform into a reusable buffer and compare against the
    // values behind the current masks. Callers redraw unconditionally (every
    // loader progress tick, every live-resize step), but assigning a shape
    // layer as a mask forces a full-view alpha re-rasterization — skip it
    // when neither the sampled peaks nor the geometry changed.
    BOOL changed = !_maskValid || !NSEqualSizes(bounds.size, _maskSize);
    if (_maskSamples.size() != count * 2) {
        _maskSamples.resize(count * 2);
        changed = YES;
    }
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        float chunkMin = m.getMin();
        float chunkMax = m.getMax();
        if (!changed && (_maskSamples[i * 2] != chunkMin || _maskSamples[i * 2 + 1] != chunkMax)) {
            changed = YES;
        }
        _maskSamples[i * 2] = chunkMin;
        _maskSamples[i * 2 + 1] = chunkMax;
    }

    self.topY = round(midY + vscale);
    self.bottomY = round(midY - vscale);

    if (!changed) {
        return;
    }
    _maskValid = YES;
    _maskSize = bounds.size;

    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        // y-up layer coords: the bar's top comes from the positive peak (max),
        // the bottom from the negative peak (min). Subtracting instead drew
        // the envelope vertically mirrored (visible on DC-offset material).
        CGFloat top = round(midY + _maskSamples[i * 2 + 1] * vscale);
        CGFloat bottom = round(midY + _maskSamples[i * 2] * vscale);
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = [self barXForIndex:i width:width barCount:count barWidth:barWidth];
        CGPathAddRect(path, NULL, CGRectMake(x, bottom, barWidth, height));
    }

    // Set the path without animation so subsequent loader chunks update
    // heights instantly. The visible hydration comes from the transform
    // animation below — which only fires on the first non-nil call per
    // waveform (subsequent calls find _hasHydrated == YES and skip it).
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _unplayedMask.path = path;
    _playedMask.path = path;
    [CATransaction commit];

    if (!_hasHydrated) {
        _hasHydrated = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.2];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        _unplayedGradient.transform = CATransform3DIdentity;
        _playedGradient.transform = CATransform3DIdentity;
        [CATransaction commit];
    }

    CGPathRelease(path);
}

@end
