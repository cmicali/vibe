//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "VibeDefaultWaveformRenderer.h"

@implementation VibeDefaultWaveformRenderer {
    CAGradientLayer *_overlayGradient;
    CGFloat _overlayGradientY;
    CGFloat _overlayGradientHeight;

    NSColor* _playedColorTop;
    NSColor* _unPlayedColorTop;
    NSColor* _playedColorBottom;
    NSColor* _unPlayedColorBottom;
}

+ (NSString *)displayName {
    return @"Vibe Default";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds{
    self = [super initWithLayer:parentLayer bounds:bounds];
    if (self) {

        _playedColorTop = [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        _unPlayedColorTop = [[NSColor whiteColor] colorWithAlphaComponent:0.89];
        _playedColorBottom = [NSColor colorWithRed:1 green:0.75 blue:0.585 alpha:0.8];
        _unPlayedColorBottom = [[NSColor whiteColor] colorWithAlphaComponent:0.55];

        [self addLayers:512 backgroundColor:_unPlayedColorTop.CGColor];

        NSArray *colors = @[
            [NSColor colorWithRed:1 green:0.2 blue:0 alpha:1],
            [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1],
        ];
//        _overlayGradient = [self createGradientLayer:colors filter:@"CISourceInCompositing"];
//        [self addOtherLayer:_overlayGradient];
        [self updateWaveform:bounds progress:0 waveform:nil];
        [self updateProgress:0 waveform:nil];
//        _overlayGradient.frame = CGRectMake(0, 0, 0, bounds.size.height);
//        CALayer *maskLayer = [[CALayer alloc] init];
//        maskLayer.frame = _overlayGradient.frame;
//        maskLayer.backgroundColor = [NSColor whiteColor].CGColor;
//        _overlayGradient.mask = maskLayer;
    }
    return self;
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    size_t count = 512;
//    CGFloat width = round(count * progress);
//    if (_overlayGradient.frame.size.width != width) {
////
//        CGRect frame = CGRectMake(0, 10, width, _overlayGradientHeight);
//        _overlayGradient.frame = frame;
//        _overlayGradient.mask.frame = frame;
//    }
    for (NSUInteger i = 0; i < count; i+=4) {
        [self setPlayedForIndex:((CGFloat)i/(CGFloat)count <= progress) index:i];
    }
}

- (void)setPlayedForIndex:(BOOL)played index:(NSUInteger)index {
    NSColor* colorTop = played ? _playedColorTop : _unPlayedColorTop;
    NSColor* colorBottom = played ? _playedColorBottom : _unPlayedColorBottom;

    [self setLayerColor:colorTop atIndex:index];
//    [self setLayerColor:[colorTop colorWithAlphaComponent:0.2] atIndex:index + 1];

    [self setLayerColor:colorBottom atIndex:index + 2];
//    [self setLayerColor:[colorBottom colorWithAlphaComponent:0.2] atIndex:index + 3];
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    CGFloat totalHeight = bounds.size.height;
    size_t count = 512;

    CGFloat vscale = totalHeight * 0.75;

    CGFloat blockWidth = 3;

    CGFloat topLineRatio = 0.70;
    CGFloat topLineY = round(totalHeight * (1-topLineRatio));

    CGFloat bottomBarSpacing = 2;
    CGFloat bottomLineY = topLineY - bottomBarSpacing;

    _overlayGradientY = bottomLineY;
    _overlayGradientHeight = bounds.size.height - _overlayGradientY;

    for (NSUInteger i = 0; i < count; i+=4) {

        AudioWaveformCacheChunk *m = [waveform chunkAtIndex:(NSUInteger) ((float) i * waveform.count / count)];
        if (!m) m = [AudioWaveform emptyChunk];

        // Top line
        CGFloat height = fabs(m->max - m->min) / 2 * vscale;
        CGFloat topBarHeight = clampMin(round(height * topLineRatio), 1);
        CGRect frame = CGRectMake(i, topLineY, blockWidth, topBarHeight);
        [self setLayerFrame:frame atIndex:i];

        // Mirror line
        CGFloat bottomBarHeight = clampMin(round(topBarHeight * (1-topLineRatio)), 0);
        frame = CGRectMake(i, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);
        [self setLayerFrame:frame atIndex:i + 2];

    }
/*
    for (NSUInteger i = 0; i < count - 4; i+=4) {

        // Top spacer line
        CGFrame frame = CGRectMake(i + blockWidth, topLineY, 1, topBarHeight);
        [self setLayerFrame:frame atIndex:i + 1];

        // Mirror spacer line
        frame = CGRectMake(i + blockWidth, bottomLineY - bottomBarHeight, 1, bottomBarHeight);
        [self setLayerFrame:frame atIndex:i + 3];

    }
*/
}

@end
