//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BasicAudioWaveformRenderer.h"
#import "AudioWaveform.h"

@implementation BasicAudioWaveformRenderer {
    NSArray<CALayer*> * _layers;
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

        NSMutableArray *layers = [NSMutableArray new];
        for (int i = 0; i < 512; ++i) {
            CALayer *layer = [[CALayer alloc] init];
            layer.backgroundColor = _unPlayedColorTop.CGColor;
            [layers addObject:layer];
            [parentLayer addSublayer:layer];
        }
        _layers = layers;

        _overlayGradient = [[CAGradientLayer alloc] init];
        CIFilter *filter = [CIFilter filterWithName:@"CISourceInCompositing"];
        [filter setDefaults];
        _overlayGradient.compositingFilter = filter;
        _overlayGradient.colors = @[
                (id)[[NSColor whiteColor] colorWithAlphaComponent:0.1].CGColor,
                (id)[[NSColor whiteColor] colorWithAlphaComponent:0.65].CGColor,
                (id)[[NSColor whiteColor] colorWithAlphaComponent:1].CGColor,
                (id)[[NSColor whiteColor] colorWithAlphaComponent:1].CGColor,
        ];
        [parentLayer addSublayer:_overlayGradient];

        [self updateWaveform:bounds progress:0 waveform:nil];

    }
    return self;
}

- (void) dealloc {
    [_overlayGradient removeFromSuperlayer];
    for (CALayer *layer in _layers) {
        [layer removeFromSuperlayer];
    }
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    size_t count = 512;
    for (NSUInteger i = 0; i < count; i++) {
        BOOL isPlayed = ((CGFloat)i/(CGFloat)count <= progress);
        [self setPlayedForIndex:isPlayed index:i];
    }
}

- (void)setPlayedForIndex:(BOOL)played index:(NSUInteger)index {
    if (played) {
        _layers[index].backgroundColor = _playedColorTop.CGColor;
    }
    else {
        _layers[index].backgroundColor = _unPlayedColorTop.CGColor;
    }
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
        CALayer *layer = _layers[i];
        layer.frame = CGRectMake(i, bottom, 1, top - bottom);
    }
}

@end
