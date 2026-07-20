//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "SonicCirrusWaveformRenderer.h"

#include <vector>
#include <cmath>

// 128 bars, each drawn with two layers: layers[i*2] is the top bar and
// layers[i*2 + 1] is the mirrored bottom bar.
#define kVibeBarCount 128

// Morph timing: exponential ease toward the target heights, settling (~95%)
// in about 3τ ≈ 0.2s. Exponential approach retargets seamlessly — a new
// target mid-morph just bends the in-flight motion.
static const CFTimeInterval kMorphTau = 0.07;
// Convergence threshold in normalized height units (bar heights span [0, 1]).
static const float kMorphEpsilon = 0.002f;
static const NSTimeInterval kMorphFrameInterval = 1.0 / 60.0;

// Geometry constants shared by morphTick's frame-skip heuristic and
// rebuildLayerFrames, so the two can't disagree on the normalized→pixels
// scale.
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

    // Morph state: what's on screen vs. where it's heading (one normalized
    // height per bar). The timer eases displayed toward target and stops
    // once they converge.
    std::vector<float> _displayedSamples;
    std::vector<float> _targetSamples;
    // Reusable target buffer — updateWaveform: runs on every loader tick and
    // live-resize frame, so a fresh allocation per call is churn. Swapped
    // with _targetSamples when the target moves.
    std::vector<float> _scratchSamples;
    CGSize _layoutSize;
    BOOL _hasWaveform;   // NO = the zero target means "empty", drawn as nothing rather than hairline bars
    NSTimer *_morphTimer;
    CFTimeInterval _lastMorphTick;
    float _pendingRebuildPx;  // screen-space bar movement accumulated since the last frame relayout
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
    [_morphTimer invalidate];
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
    if (_scratchSamples.size() != count) {
        _scratchSamples.resize(count);
    }
    if (waveform) {
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
            _scratchSamples[i] = fabsf(m.getMax() - m.getMin()) / 2;
        }
    }
    else {
        std::fill(_scratchSamples.begin(), _scratchSamples.end(), 0.0f);
    }

    BOOL geometryChanged = !NSEqualSizes(bounds.size, _layoutSize);
    _layoutSize = bounds.size;
    // The empty↔loaded flip is tracked separately from sample changes: a
    // silent track's all-zero waveform is sample-identical to the collapsed
    // "no waveform" target but draws hairlines instead of nothing.
    BOOL hasWaveformChanged = (_hasWaveform != (waveform != nil));
    _hasWaveform = (waveform != nil);
    if (_displayedSamples.size() != count) {
        // First draw: start collapsed so the first waveform grows out of the
        // baseline.
        _displayedSamples.assign(count, 0.0f);
        geometryChanged = YES;
    }
    BOOL targetChanged = (_scratchSamples != _targetSamples);
    if (!targetChanged && !geometryChanged && !hasWaveformChanged) {
        // No-op redraw — skip the 256 frame writes.
        return;
    }
    if (targetChanged) {
        std::swap(_targetSamples, _scratchSamples);
    }
    if (geometryChanged || (hasWaveformChanged && !targetChanged)) {
        // Geometry: remap the on-screen bars instantly — a live resize must
        // track the window, not ease after it. hasWaveform flip alone: no
        // morph will run (samples identical) but the hairline floor changed,
        // so redraw in place.
        [self rebuildLayerFrames];
    }
    if (targetChanged) {
        [self startMorphTimer];
    }
}

// Runs in the main run loop's common modes so morphs don't freeze during
// menu tracking or a live resize.
- (void)startMorphTimer {
    if (_morphTimer) {
        return; // already easing — the updated target just bends the motion
    }
    _lastMorphTick = CACurrentMediaTime();
    __weak __typeof__(self) weakSelf = self;
    _morphTimer = [NSTimer timerWithTimeInterval:kMorphFrameInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf morphTick];
    }];
    [NSRunLoop.mainRunLoop addTimer:_morphTimer forMode:NSRunLoopCommonModes];
}

- (void)morphTick {
    CFTimeInterval now = CACurrentMediaTime();
    // Clamp dt: after a stall (debugger pause, occluded window) one huge
    // step would snap the morph instead of easing it.
    CFTimeInterval dt = MIN(MAX(now - _lastMorphTick, 0), 0.1);
    _lastMorphTick = now;
    float k = (float)(1.0 - exp(-dt / kMorphTau));
    float maxDistance = 0;
    for (size_t i = 0; i < _displayedSamples.size(); i++) {
        float d = _targetSamples[i] - _displayedSamples[i];
        maxDistance = MAX(maxDistance, fabsf(d));
        _displayedSamples[i] += d * k;
    }
    if (maxDistance < kMorphEpsilon) {
        _displayedSamples = _targetSamples;
        [_morphTimer invalidate];
        _morphTimer = nil;
        [self rebuildLayerFrames]; // final settle always draws the exact target
        return;
    }
    // The exponential tail spends many frames moving imperceptibly — skip
    // relayouts until the fastest bar has accumulated ~a quarter pixel of
    // motion.
    CGFloat vscale = _layoutSize.height * kBarAmplitude * kTopLineRatio;
    _pendingRebuildPx += (float)(maxDistance * k * vscale);
    if (_pendingRebuildPx >= 0.25f) {
        [self rebuildLayerFrames];
    }
}

// Lay the bar layers out for the currently displayed samples. Heights round
// to the DEVICE-pixel grid on every draw: edges stay crisp, quantization
// stays at an imperceptible 1-device-pixel step, and the settle draw is
// identical to the last animation frame — no end-of-morph shift.
- (void)rebuildLayerFrames {
    _pendingRebuildPx = 0;
    NSUInteger count = _displayedSamples.size();
    if (count == 0) {
        return;
    }

    CGFloat totalHeight = _layoutSize.height;
    CGFloat width = _layoutSize.width;

    CGFloat vscale = totalHeight * kBarAmplitude;

    CGFloat barPitch = width / (CGFloat)count;
    CGFloat blockWidth = clampMin(barPitch * kBlockWidthRatio, 1);

    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;

    // With no waveform, bars may shrink to nothing; with one, silent and
    // not-yet-loaded chunks keep a 1px hairline floor.
    CGFloat minHeight = _hasWaveform ? 1 : 0;
    CGFloat scale = self.parentLayer.contentsScale;
    if (scale <= 0) scale = 2;
    CGFloat pixel = 1 / scale;

    // Track the actual extents for the view's click hit-band.
    CGFloat maxTop = topLineY;
    CGFloat minBottom = bottomLineY;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {

        CGFloat x = barPitch * (CGFloat)i;

        // Top line
        CGFloat height = _displayedSamples[i] * vscale;
        CGFloat topBarHeight = round(height * kTopLineRatio / pixel) * pixel;
        topBarHeight = MAX(topBarHeight, minHeight);
        _layers[i * 2].frame = CGRectMake(x, topLineY, blockWidth, topBarHeight);

        // Mirror line
        CGFloat bottomBarHeight = round(topBarHeight * (1 - kTopLineRatio) / pixel) * pixel;
        _layers[i * 2 + 1].frame = CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);

        maxTop = MAX(maxTop, topLineY + topBarHeight);
        minBottom = MIN(minBottom, bottomLineY - bottomBarHeight);
    }
    [CATransaction commit];

    self.topY = maxTop;
    self.bottomY = minBottom;
}

@end
