//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "SonicCirrusWaveformRenderer.h"
#import "WaveformMorphEngine.h"

#include <vector>
#include <cmath>

// 128 bars, each drawn with two layers: layers[i*2] is the top bar and
// layers[i*2 + 1] is the mirrored bottom bar.
#define kVibeBarCount 128

// Geometry constants shared by the morph engine's frame-skip heuristic (the
// vscale block handed to it in init), rebuildLayerFrames, and the seek hit
// band (seekHitBandForBounds:), so they can't disagree on the
// normalized→pixels scale.
static const CGFloat kBarAmplitude = 0.75;     // full bar height as a fraction of the view height
static const CGFloat kTopLineRatio = 0.70;     // top bar's share of the height; the mirror gets the rest
static const CGFloat kBlockWidthRatio = 0.75;  // bar width as a fraction of the bar pitch
static const CGFloat kBottomBarSpacing = 2;    // gap between the top baseline and the mirror bars

@implementation SonicCirrusWaveformRenderer {
    // The only renderer that draws with a flat array of bar layers (the
    // Detailed family draws gradient+mask layers), so the layer machinery
    // lives here rather than in the base class.
    NSArray<CALayer*>* _layers;

    NSColor* _playedColorTop;
    NSColor* _unPlayedColorTop;
    NSColor* _playedColorBottom;
    NSColor* _unPlayedColorBottom;

    // Samples: one normalized height per bar. Rebuild callback:
    // rebuildLayerFrames.
    WaveformMorphEngine *_morph;
}

+ (NSString *)displayName {
    return @"Sonic Cirrus";
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {

        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return height * kBarAmplitude * kTopLineRatio; }
                       rebuild:^{ [weakSelf rebuildLayerFrames]; }];

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

- (void)setLayerColor:(NSColor *)color atIndex:(NSUInteger)index {
    CGColorRef c = color.CGColor;
    CALayer *layer = _layers[index];
    if (!CGColorEqualToColor(layer.backgroundColor, c)) {
        layer.backgroundColor = c;
    }
}

// Full-amplitude extents from the fixed geometry constants — NOT the bars
// currently on screen, whose extents collapse to a sliver on quiet tracks
// and make the seek band impossible to hit.
- (NSRect)seekHitBandForBounds:(NSRect)bounds {
    CGFloat totalHeight = bounds.size.height;
    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;
    CGFloat maxTopBarHeight = totalHeight * kBarAmplitude * kTopLineRatio;
    CGFloat topY = topLineY + maxTopBarHeight;
    CGFloat bottomY = bottomLineY - maxTopBarHeight * (1 - kTopLineRatio);
    return NSMakeRect(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
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

    // Build the morph target: each bar's normalized peak-to-peak height, or
    // all-zero when there is no waveform — a track change collapses the old
    // bars toward the baseline until the new waveform retargets them.
    std::vector<float> &target = [_morph targetScratchWithCount:count];
    if (waveform) {
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
            target[i] = fabsf(m.getMax() - m.getMin()) / 2;
        }
    }
    else {
        std::fill(target.begin(), target.end(), 0.0f);
    }
    [_morph commitTargetForSize:bounds.size hasWaveform:(waveform != nil)];
}

// Lay the bar layers out for the currently displayed samples (the morph
// engine's rebuild callback). Heights round to the DEVICE-pixel grid on every
// draw: edges stay crisp, quantization stays at an imperceptible
// 1-device-pixel step, and the settle draw is identical to the last animation
// frame — no end-of-morph shift.
- (void)rebuildLayerFrames {
    const std::vector<float> &samples = [_morph displayedSamples];
    NSUInteger count = samples.size();
    if (count == 0) {
        return;
    }

    CGFloat totalHeight = _morph.size.height;
    CGFloat width = _morph.size.width;

    CGFloat vscale = totalHeight * kBarAmplitude;

    CGFloat barPitch = width / (CGFloat)count;
    CGFloat blockWidth = clampMin(barPitch * kBlockWidthRatio, 1);

    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;

    // With no waveform, bars may shrink to nothing; with one, silent and
    // not-yet-loaded chunks keep a 1px hairline floor.
    CGFloat minHeight = _morph.hasWaveform ? 1 : 0;
    CGFloat scale = self.parentLayer.contentsScale;
    if (scale <= 0) scale = 2;
    CGFloat pixel = 1 / scale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {

        CGFloat x = barPitch * (CGFloat)i;

        // Top line
        CGFloat height = samples[i] * vscale;
        CGFloat topBarHeight = round(height * kTopLineRatio / pixel) * pixel;
        topBarHeight = MAX(topBarHeight, minHeight);
        _layers[i * 2].frame = CGRectMake(x, topLineY, blockWidth, topBarHeight);

        // Mirror line
        CGFloat bottomBarHeight = round(topBarHeight * (1 - kTopLineRatio) / pixel) * pixel;
        _layers[i * 2 + 1].frame = CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);
    }
    [CATransaction commit];
}

@end
