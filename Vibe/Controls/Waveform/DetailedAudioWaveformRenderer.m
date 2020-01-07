//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"

@implementation DetailedAudioWaveformRenderer {
    NSColor* _playedColor;
    NSColor* _unPlayedColor;
    CAGradientLayer *_overlayGradient;
}

+ (NSString *)displayName {
    return @"Detailed";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds{
    self = [super initWithLayer:parentLayer bounds:bounds];
    if (self) {

        _playedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.95];
        _unPlayedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.5];

        [self addLayers:1024 backgroundColor:_unPlayedColor.CGColor];

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
    size_t count = self.layers.count;
    for (NSUInteger i = 0; i < count; i++) {
        BOOL played = ((CGFloat)i/(CGFloat)count <= progress);
        NSColor* color = played ? _playedColor : _unPlayedColor;
        [self setLayerColor:color atIndex:i];
    }
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    _overlayGradient.frame = bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat vscale = (height / 2) * 0.75;
    CGFloat midY = height / 2;
    CGFloat barWidth = bounds.size.width / waveform.count;
    for (NSUInteger i = 0; i < waveform.count; i++) {
        AudioWaveformCacheChunk *m = [waveform chunkAtIndex:i];
        if (!m) m = [AudioWaveform emptyChunk];
        CGFloat top = round(midY - m->min * vscale);
        CGFloat bottom = round(midY - m->max * vscale);
        height = top - bottom;
        if (height < 1) height = 1;
        CGFloat x = width * (CGFloat)i/(CGFloat)waveform.count;
        CGRect frame = CGRectMake(x, bottom, barWidth, height);
        [self setLayerFrame:frame atIndex:i];
    }
}

@end
