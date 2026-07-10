//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "VibeDefaultWaveformRenderer.h"

// 128 bars, each drawn with two layers: layers[i*2] is the top bar and
// layers[i*2 + 1] is the mirrored bottom bar.
#define kVibeBarCount 128

@implementation VibeDefaultWaveformRenderer {
    NSColor* _playedColorTop;
    NSColor* _unPlayedColorTop;
    NSColor* _playedColorBottom;
    NSColor* _unPlayedColorBottom;
}

+ (NSString *)displayName {
    return @"Vibe Default";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {

        _playedColorTop = [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        _unPlayedColorTop = [[NSColor whiteColor] colorWithAlphaComponent:0.89];
        _playedColorBottom = [NSColor colorWithRed:1 green:0.75 blue:0.585 alpha:0.8];
        _unPlayedColorBottom = [[NSColor whiteColor] colorWithAlphaComponent:0.55];

        [self addLayers:kVibeBarCount * 2 backgroundColor:_unPlayedColorTop.CGColor];
        // The mirrored bottom bars are dimmer than the top bars at all times.
        for (NSUInteger i = 0; i < kVibeBarCount; i++) {
            self.layers[i * 2 + 1].backgroundColor = _unPlayedColorBottom.CGColor;
        }

        [self updateWaveform:bounds progress:0 waveform:nil];
        [self updateProgress:0 waveform:nil];
    }
    return self;
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    NSInteger count = kVibeBarCount;
    NSInteger newBoundary = (NSInteger)round((CGFloat)count * progress);
    if (newBoundary < 0) newBoundary = 0;
    if (newBoundary > count) newBoundary = count;

    NSInteger oldBoundary = self.lastProgressBoundary;
    NSInteger start, end;
    if (oldBoundary < 0) {
        // Sentinel after updateColors: — repaint everything.
        start = 0;
        end = count;
    } else {
        start = MIN(oldBoundary, newBoundary);
        end = MAX(oldBoundary, newBoundary);
    }

    for (NSInteger i = start; i < end; i++) {
        BOOL played = (i < newBoundary);
        NSColor *colorTop = played ? _playedColorTop : _unPlayedColorTop;
        NSColor *colorBottom = played ? _playedColorBottom : _unPlayedColorBottom;
        setLayerColor(colorTop, i * 2);
        setLayerColor(colorBottom, i * 2 + 1);
    }
    self.lastProgressBoundary = newBoundary;
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    NSUInteger count = kVibeBarCount;

    if (!waveform) {
        // Clear stale bars from the previous track.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (NSUInteger i = 0; i < count * 2; i++) {
            self.layers[i].frame = CGRectZero;
        }
        [CATransaction commit];
        return;
    }

    CGFloat totalHeight = bounds.size.height;
    CGFloat width = bounds.size.width;

    CGFloat vscale = totalHeight * 0.75;

    CGFloat barPitch = width / (CGFloat)count;
    CGFloat blockWidth = clampMin(barPitch * 0.75, 1);

    CGFloat topLineRatio = 0.70;
    CGFloat topLineY = round(totalHeight * (1-topLineRatio));

    CGFloat bottomBarSpacing = 2;
    CGFloat bottomLineY = topLineY - bottomBarSpacing;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {

        AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
        CGFloat x = barPitch * (CGFloat)i;

        // Top line
        CGFloat height = fabs(m.getMax() - m.getMin()) / 2 * vscale;
        CGFloat topBarHeight = clampMin(round(height * topLineRatio), 1);
        CGRect frame = CGRectMake(x, topLineY, blockWidth, topBarHeight);
        setLayerFrame(frame, i * 2);

        // Mirror line
        CGFloat bottomBarHeight = clampMin(round(topBarHeight * (1-topLineRatio)), 0);
        frame = CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);
        setLayerFrame(frame, i * 2 + 1);

    }
    [CATransaction commit];
}

@end
