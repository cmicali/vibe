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

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        NSUInteger numBars = 128;
        _overlayGradient = [self createGradientLayer:@"CISourceInCompositing"];
        [self updateColors:isDark];
        [self addLayers:numBars backgroundColor:_unPlayedColor.CGColor];
        [self addOtherLayer:_overlayGradient];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    NSColor *waveformColor = isDark ? [NSColor blackColor] : [NSColor whiteColor];
    NSColor *gradientColor = isDark ? [NSColor whiteColor] : [NSColor blackColor];
    _playedColor = [waveformColor colorWithAlphaComponent:0.95];
    _unPlayedColor = [waveformColor colorWithAlphaComponent:0.5];
    NSArray *colors = @[
            [gradientColor colorWithAlphaComponent:0.1],
            [gradientColor colorWithAlphaComponent:0.65],
            [gradientColor colorWithAlphaComponent:1],
            [gradientColor colorWithAlphaComponent:1],
    ];
    if (!isDark) colors = [[colors reverseObjectEnumerator] allObjects];
    [self setGradientLayerColors:_overlayGradient colors:colors];
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
    CGFloat barWidth = 3;

    size_t count = self.layers.count;

    for (NSUInteger i = 0; i < count; i++) {
        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        CGFloat top = round(midY - m.getMin() * vscale);
        CGFloat bottom = round(midY - m.getMax() * vscale);
        CGFloat height = MAX(top - bottom, 1);
        CGFloat x = width * i / count;
        CGRect frame = CGRectMake(x, bottom, barWidth, height);
        setLayerFrame(frame, i);
    }

}

@end
