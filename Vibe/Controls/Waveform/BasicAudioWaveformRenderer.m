//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BasicAudioWaveformRenderer.h"
#import "AudioWaveform.h"

@implementation BasicAudioWaveformRenderer {
    NSColor* _playedColorTop;
    NSColor* _unPlayedColorTop;
    CAGradientLayer *_overlayGradient;
}

+ (NSString *)displayName {
    return @"Basic";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds{
    self = [super initWithLayer:parentLayer bounds:bounds];
    if (self) {

        _playedColorTop = [[NSColor whiteColor] colorWithAlphaComponent:0.95];
        _unPlayedColorTop = [[NSColor whiteColor] colorWithAlphaComponent:0.5];

        [self addLayers:512 backgroundColor:_unPlayedColorTop.CGColor];

        NSArray *colors = @[
            [[NSColor whiteColor] colorWithAlphaComponent:0.1],
            [[NSColor whiteColor] colorWithAlphaComponent:0.65],
            [[NSColor whiteColor] colorWithAlphaComponent:1],
            [[NSColor whiteColor] colorWithAlphaComponent:1],
        ];
        _overlayGradient = [self createGradientLayer:colors filter:@"CISourceInCompositing"];
        [self addOtherLayer:_overlayGradient];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    size_t count = 512;
    [CATransaction begin];
    CATransaction.animationDuration = 0.25;
    if (progress > self.progress) {
        for (NSUInteger i = 0; i < count; i++) {
            [self setPlayedForIndex:((CGFloat)i/(CGFloat)count <= progress) index:i];
        }
    }
    else {
        for (NSUInteger i = count; i > 0; i--) {
            [self setPlayedForIndex:((CGFloat)i/(CGFloat)count <= progress) index:i-1];
        }
    }
    [CATransaction commit];
}

- (void)setPlayedForIndex:(BOOL)played index:(NSUInteger)index {
    CGColorRef color = played ? _playedColorTop.CGColor : _unPlayedColorTop.CGColor;
    CALayer *layer = self.layers[index];
    if (CGColorEqualToColor(layer.backgroundColor, color)) {
        return;
    }
//    CABasicAnimation *a = [CABasicAnimation new];
//    a.keyPath = @"backgroundColor";
//    a.fromValue = (id)layer.backgroundColor;
//    a.toValue = (__bridge id)color;
//    a.beginTime = CACurrentMediaTime() + ((CGFloat)index)/128;
//    a.fillMode = kCAFillModeForwards;
//    [layer addAnimation:a forKey:@"basic"];
    layer.backgroundColor = color;
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    _overlayGradient.frame = bounds;
    CGFloat height = bounds.size.height;
    size_t count = 512;
    CGFloat vscale = (height / 2) * 0.70;
    CGFloat midY = height / 2;
    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk *m = [waveform chunkAtIndex:(NSUInteger) ((float) i * waveform.count / count)];
        if (!m) m = [AudioWaveform emptyChunk];
        CGFloat top = round(midY - m->min * vscale);
        CGFloat bottom = round(midY - m->max * vscale);
        height = top - bottom;
        if (height < 1) height = 1;
        CGRect frame = CGRectMake(i, bottom, 1, height);
        [self setLayerFrame:frame atIndex:i];
    }
}

@end
