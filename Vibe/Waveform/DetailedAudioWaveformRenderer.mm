//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"

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
}

+ (NSString *)displayName {
    return @"Detailed";
}

- (NSUInteger)numLayers {
    return 1024;
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
    _playedMask = [CAShapeLayer layer];
    _playedMask.fillColor = [NSColor whiteColor].CGColor;
    _playedMask.contentsScale = scale;
    _playedGradient.mask = _playedMask;
    [_playedClip addSublayer:_playedGradient];
    [self.parentLayer addSublayer:_playedClip];
}

- (void)dealloc {
    [_unplayedGradient removeFromSuperlayer];
    [_playedClip removeFromSuperlayer];
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    _gradientColor = isDark ? [NSColor whiteColor] : [NSColor blackColor];

    // Played: same alpha profile as the old design (transparent at the
    // far-from-center edge, fully opaque at the top).
    NSArray *playedColors = @[
            [_gradientColor colorWithAlphaComponent:0.1],
            [_gradientColor colorWithAlphaComponent:0.65],
            [_gradientColor colorWithAlphaComponent:1.0],
            [_gradientColor colorWithAlphaComponent:1.0],
    ];
    // Unplayed: half the alphas of played, so the played region is clearly
    // brighter where the two regions meet.
    NSArray *unplayedColors = @[
            [_gradientColor colorWithAlphaComponent:0.05],
            [_gradientColor colorWithAlphaComponent:0.325],
            [_gradientColor colorWithAlphaComponent:0.5],
            [_gradientColor colorWithAlphaComponent:0.5],
    ];
    if (!isDark) {
        playedColors = [[playedColors reverseObjectEnumerator] allObjects];
        unplayedColors = [[unplayedColors reverseObjectEnumerator] allObjects];
    }
    [self setGradientLayerColors:_playedGradient colors:playedColors];
    [self setGradientLayerColors:_unplayedGradient colors:unplayedColors];
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
    CGFloat barWidth = width / (CGFloat)count;

    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        CGFloat top = round(midY - m.getMin() * vscale);
        CGFloat bottom = round(midY - m.getMax() * vscale);
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = barWidth * (CGFloat)i;
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

    self.topY = round(midY + vscale);
    self.bottomY = round(midY - vscale);
}

@end
