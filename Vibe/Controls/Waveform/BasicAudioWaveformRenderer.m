//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BasicAudioWaveformRenderer.h"

@implementation BasicAudioWaveformRenderer {
    NSColor* _playedColor;
    NSColor* _unPlayedColor;
    CAGradientLayer *_overlayGradient;
}

+ (NSString *)displayName {
    return @"Basic";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds{
    self = [super initWithLayer:parentLayer bounds:bounds];
    if (self) {

        _playedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.95];
        _unPlayedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.5];

        [self addLayers:512 backgroundColor:_unPlayedColor.CGColor];

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
    for (NSUInteger i = 0; i < count; i++) {
        [self setPlayedForIndex:((CGFloat)i/(CGFloat)count <= progress) index:i];
    }
}

- (void)setPlayedForIndex:(BOOL)played index:(NSUInteger)index {
    CGColorRef color = played ? _playedColor.CGColor : _unPlayedColor.CGColor;
    CALayer *layer = self.layers[index];
    if (CGColorEqualToColor(layer.backgroundColor, color)) {
        return;
    }
    layer.backgroundColor = color;
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    _overlayGradient.frame = bounds;
    CGFloat height = bounds.size.height;
    size_t count = 512;
    CGFloat vscale = (height / 2) * 0.75;
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
