//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BasicAudioWaveformRenderer.h"

#define kBasicBarCount 128

@implementation BasicAudioWaveformRenderer {
    NSColor *_gradientColor;

    CAGradientLayer *_unplayedGradient;
    CAShapeLayer *_unplayedMask;

    CALayer *_playedClip;
    CAGradientLayer *_playedGradient;
    CAShapeLayer *_playedMask;

    BOOL _hasHydrated;
}

+ (NSString *)displayName {
    return @"Basic";
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
    const float kWaveformOpacity = 0.75f;

    CGFloat scale = self.parentLayer.contentsScale;

    // Path updates are applied inside setDisableActions:YES transactions in
    // updateWaveform:; the visible hydration comes from the grow-from-midline
    // transform animation there, not from implicit path animations.
    _unplayedGradient = [CAGradientLayer layer];
    _unplayedGradient.opacity = kWaveformOpacity;
    _unplayedGradient.contentsScale = scale;
    _unplayedMask = [CAShapeLayer layer];
    _unplayedMask.fillColor = [NSColor whiteColor].CGColor;
    _unplayedMask.contentsScale = scale;
    _unplayedGradient.mask = _unplayedMask;
    [self.parentLayer addSublayer:_unplayedGradient];

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
    NSArray *playedColors = @[
            [_gradientColor colorWithAlphaComponent:0.1],
            [_gradientColor colorWithAlphaComponent:0.65],
            [_gradientColor colorWithAlphaComponent:1.0],
            [_gradientColor colorWithAlphaComponent:1.0],
    ];
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
    // Set bounds + position on transformed gradient layers — see the matching
    // comment in DetailedAudioWaveformRenderer for the rationale.
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CGPoint center = CGPointMake(NSMidX(bounds), NSMidY(bounds));
    _unplayedGradient.bounds = localBounds;
    _unplayedGradient.position = center;
    _playedGradient.bounds = localBounds;
    _playedGradient.position = center;
    _unplayedMask.frame = localBounds;
    _playedMask.frame = localBounds;
    [self updateProgress:progress waveform:waveform];

    if (!waveform) {
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

    NSUInteger count = kBasicBarCount;
    CGFloat width = bounds.size.width;
    CGFloat vscale = (bounds.size.height / 2) * 0.75;
    CGFloat midY = bounds.size.height / 2;
    CGFloat barWidth = 3;

    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        CGFloat top = round(midY - m.getMin() * vscale);
        CGFloat bottom = round(midY - m.getMax() * vscale);
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = width * (CGFloat)i / (CGFloat)count;
        CGPathAddRect(path, NULL, CGRectMake(x, bottom, barWidth, height));
    }

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
