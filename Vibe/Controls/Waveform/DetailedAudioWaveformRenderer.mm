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

- (NSUInteger)numLayers {
    return 1024;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds{
    self = [super initWithLayer:parentLayer bounds:bounds];
    if (self) {

        _playedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.95];
        _unPlayedColor = [[NSColor whiteColor] colorWithAlphaComponent:0.5];

        [self addLayers:self.numLayers backgroundColor:_unPlayedColor.CGColor];

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
        setLayerColor(played ? _playedColor : _unPlayedColor, i);
    }
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    _overlayGradient.frame = bounds;

    if (!waveform) return;

    CGFloat width = bounds.size.width;
    CGFloat vscale = (bounds.size.height / 2) * 0.75;
    CGFloat midY = bounds.size.height / 2;

    size_t count = self.layers.count;
    CGFloat barWidth = width / self.layers.count;

    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        CGFloat top = round(midY - m.getMin() * vscale);
        CGFloat bottom = round(midY - m.getMax() * vscale);
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = ((CGFloat)width / (CGFloat)count) * (CGFloat)i;
        CGRect frame = CGRectMake(x, bottom, barWidth, height);
        setLayerFrame(frame, i);
    }

}

@end