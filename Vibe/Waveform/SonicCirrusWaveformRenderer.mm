//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "SonicCirrusWaveformRenderer.h"

// 128 bars, each drawn with two layers: layers[i*2] is the top bar and
// layers[i*2 + 1] is the mirrored bottom bar.
#define kVibeBarCount 128

@implementation SonicCirrusWaveformRenderer {
    // The only renderer that draws with a flat array of bar layers (the
    // Detailed family draws gradient+mask layers), so the layer machinery
    // lives here rather than in the base class.
    NSArray<CALayer*>* _layers;

    NSColor* _playedColorTop;
    NSColor* _unPlayedColorTop;
    NSColor* _playedColorBottom;
    NSColor* _unPlayedColorBottom;
}

+ (NSString *)displayName {
    return @"Sonic Cirrus";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {

        // Same derivation as light/dark switches — one source of truth for
        // the palette.
        [self updateColors:isDark];

        [self addLayers:kVibeBarCount * 2 backgroundColor:_unPlayedColorTop.CGColor];
        // The mirrored bottom bars are dimmer than the top bars at all times.
        for (NSUInteger i = 0; i < kVibeBarCount; i++) {
            _layers[i * 2 + 1].backgroundColor = _unPlayedColorBottom.CGColor;
        }

        [self updateWaveform:bounds progress:0 waveform:nil];
        [self updateProgress:0 waveform:nil];
    }
    return self;
}

- (void)dealloc {
    for (CALayer *layer in _layers) {
        [layer removeFromSuperlayer];
    }
}

- (void)updateColors:(BOOL)isDark {
    // super sets lastProgressBoundary to -1, so the next updateProgress:
    // repaints every bar with the new colors.
    [super updateColors:isDark];
    // The unplayed bars follow the appearance (fixed white is near-invisible
    // on a light background); the played orange reads fine on both.
    NSColor *base = isDark ? [NSColor whiteColor] : [NSColor blackColor];
    _playedColorTop = [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1];
    _unPlayedColorTop = [base colorWithAlphaComponent:0.89];
    _playedColorBottom = [NSColor colorWithRed:1 green:0.75 blue:0.585 alpha:0.8];
    _unPlayedColorBottom = [base colorWithAlphaComponent:0.55];
}

- (void)addLayers:(NSUInteger)numLayers backgroundColor:(CGColorRef)color {
    CGFloat scale = self.parentLayer.contentsScale;
    NSMutableArray *layers = [NSMutableArray new];
    for (NSUInteger i = 0; i < numLayers; ++i) {
        CALayer *layer = [[CALayer alloc] init];
        layer.backgroundColor = color;
        layer.contentsScale = scale;
        [layers addObject:layer];
        [self.parentLayer addSublayer:layer];
    }
    _layers = layers;
}

- (void)setLayerFrame:(CGRect)frame atIndex:(NSUInteger)index {
    _layers[index].frame = frame;
    CGFloat bottom = frame.origin.y;
    CGFloat top = bottom + frame.size.height;
    if (top > self.topY) {
        self.topY = top;
    }
    if (bottom < self.bottomY) {
        self.bottomY = bottom;
    }
}

- (void)setLayerColor:(NSColor *)color atIndex:(NSUInteger)index {
    CGColorRef c = color.CGColor;
    CALayer *layer = _layers[index];
    if (!CGColorEqualToColor(layer.backgroundColor, c)) {
        layer.backgroundColor = c;
    }
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
        [self setLayerColor:colorTop atIndex:(NSUInteger)(i * 2)];
        [self setLayerColor:colorBottom atIndex:(NSUInteger)(i * 2 + 1)];
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
            _layers[i].frame = CGRectZero;
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
        [self setLayerFrame:frame atIndex:i * 2];

        // Mirror line
        CGFloat bottomBarHeight = round(topBarHeight * (1-topLineRatio));
        frame = CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);
        [self setLayerFrame:frame atIndex:i * 2 + 1];

    }
    [CATransaction commit];
}

@end
