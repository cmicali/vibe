//
//  WaveformMorphEngine.mm
//  Vibe
//

#import "WaveformMorphEngine.h"

#include <cmath>

// The ease's time constant: ~95% settled in 3τ, about 0.2s.
static const CFTimeInterval kMorphTau = 0.07;
// The convergence threshold, in the caller's normalized sample units.
static const float kMorphEpsilon = 0.002f;
static const NSTimeInterval kMorphFrameInterval = 1.0 / 60.0;

@implementation WaveformMorphEngine {
    std::vector<float> _displayedSamples;
    std::vector<float> _targetSamples;
    // Holds the stale target after a swap, until the next fill.
    std::vector<float> _scratchSamples;
    CGSize _size;
    BOOL _hasWaveform;   // NO = the zero target means "empty", drawn as nothing rather than hairline bars
    // The fast-path gate. Compare-only; may dangle.
    const void *_lastTargetIdentity;
    NSUInteger _lastTargetCount;
    BOOL _targetInvalidated;
    NSTimer *_morphTimer;
    CFTimeInterval _lastMorphTick;
    float _pendingRebuildPx;  // screen-space bar movement accumulated since the last rebuild
    CGFloat (^_vscale)(CGFloat height);
    void (^_rebuild)(void);
}

- (instancetype)initWithVScale:(CGFloat (^)(CGFloat height))vscale
                       rebuild:(void (^)(void))rebuild {
    self = [super init];
    if (self) {
        _vscale = [vscale copy];
        _rebuild = [rebuild copy];
        _samplesPerBar = 1;
    }
    return self;
}

- (void)dealloc {
    // The block holds the engine weakly; the timer would fire forever.
    [_morphTimer invalidate];
}

- (void)updateTargetForSize:(CGSize)size
                   identity:(const void *)identity
                      count:(NSUInteger)count
                       fill:(void (^)(std::vector<float> &target))fill {
    // A settled picture resampled for a new width is layout, not new audio:
    // easing it doubles a resize's rebuilds and repaints after it stops.
    BOOL animate = _targetInvalidated || identity != _lastTargetIdentity || _morphTimer != nil;
    if (!_targetInvalidated && identity == _lastTargetIdentity && count == _lastTargetCount) {
        // Leave the scratch alone: it holds the stale target, and comparing
        // against it would morph back to it.
        BOOL geometryChanged = !CGSizeEqualToSize(size, _size);
        _size = size;
        if (geometryChanged) {
            [self runRebuild];
        }
        return;
    }
    _lastTargetIdentity = identity;
    _lastTargetCount = count;
    _targetInvalidated = NO;
    _scratchSamples.resize(count);
    if (identity) {
        VibeSignpostBegin(waveform_target);
        fill(_scratchSamples);
        VibeSignpostEnd(waveform_target);
    } else {
        std::fill(_scratchSamples.begin(), _scratchSamples.end(), 0.0f);
    }
    [self commitTargetForSize:size hasWaveform:(identity != NULL) animate:animate];
}

- (void)invalidateTarget {
    _targetInvalidated = YES;
}

- (const std::vector<float> &)displayedSamples {
    return _displayedSamples;
}

- (void)dipDisplayedSamplesFromFraction:(double)from toFraction:(double)to {
    if (!_hasWaveform || _displayedSamples.empty()) {
        return;
    }
    double count = (double)_displayedSamples.size();
    size_t start = (size_t)MAX(floor(from * count), 0.0);
    size_t end = (size_t)MIN(ceil(to * count), count);
    // Outward to bar boundaries, or a Detailed [min, max] edge bar is
    // half-zeroed.
    size_t stride = MAX(_samplesPerBar, (NSUInteger)1);
    start -= start % stride;
    end = MIN(end + (stride - end % stride) % stride, _displayedSamples.size());
    BOOL dipped = NO;
    for (size_t i = start; i < end; i++) {
        if (_displayedSamples[i] != 0.0f) {
            _displayedSamples[i] = 0.0f;
            dipped = YES;
        }
    }
    if (!dipped) {
        return;
    }
    // Now, or the first tick eases the notch back before it is seen at zero.
    [self runRebuild];
    [self startMorphTimer];
}

- (CGSize)size {
    return _size;
}

- (CGFloat)barMinHeight {
    return _hasWaveform ? 1 : 0;
}

- (BOOL)isSettled {
    return _morphTimer == nil;
}

// updateTargetForSize:'s slow path; the scratch must be freshly filled.
- (void)commitTargetForSize:(CGSize)size hasWaveform:(BOOL)hasWaveform animate:(BOOL)animate {
    BOOL geometryChanged = !CGSizeEqualToSize(size, _size);
    _size = size;
    BOOL hasWaveformChanged = (_hasWaveform != hasWaveform);
    _hasWaveform = hasWaveform;
    BOOL targetChanged = (_scratchSamples != _targetSamples);
    if (!targetChanged && !geometryChanged && !hasWaveformChanged) {
        return;
    }
    if (targetChanged) {
        std::swap(_targetSamples, _scratchSamples);
    }
    if (!animate) {
        _displayedSamples = _targetSamples;
        [self runRebuild];
        return;
    }
    if (_displayedSamples.size() != _targetSamples.size()) {
        if (_displayedSamples.empty()) {
            // The first build grows out of the midline.
            _displayedSamples.assign(_targetSamples.size(), 0.0f);
        } else {
            // A count change mid-picture is a resize: carry the shape over
            // rather than collapsing it every few points of drag.
            [self resampleDisplayedToCount:_targetSamples.size()];
        }
        geometryChanged = YES;
    }
    // A bare hasWaveform flip: no morph, but the hairline floor changed.
    if (geometryChanged || (hasWaveformChanged && !targetChanged)) {
        [self runRebuild];
    }
    if (targetChanged) {
        [self startMorphTimer];
    }
}

// Nearest-bar, in samplesPerBar strides so a [min, max] pair travels
// together.
- (void)resampleDisplayedToCount:(NSUInteger)count {
    size_t stride = MAX(_samplesPerBar, (NSUInteger)1);
    size_t oldBars = _displayedSamples.size() / stride;
    size_t newBars = count / stride;
    std::vector<float> resampled(count, 0.0f);
    for (size_t bar = 0; oldBars > 0 && bar < newBars; bar++) {
        size_t src = bar * oldBars / newBars;
        for (size_t s = 0; s < stride; s++) {
            resampled[bar * stride + s] = _displayedSamples[src * stride + s];
        }
    }
    _displayedSamples = std::move(resampled);
}

- (void)rebuildNow {
    [self runRebuild];
}

- (void)settleImmediately {
    if (!_morphTimer && _displayedSamples == _targetSamples) {
        return;
    }
    [_morphTimer invalidate];
    _morphTimer = nil; // settled BEFORE the rebuild — see isSettled
    _displayedSamples = _targetSamples;
    [self runRebuild];
}

- (void)runRebuild {
    _pendingRebuildPx = 0;
    if (_rebuild) {
        _rebuild();
    }
}

// Common modes, so morphs do not freeze during menu tracking or live resize.
- (void)startMorphTimer {
    if (_morphTimer) {
        return; // already easing — the updated target just bends the motion
    }
    // The renderer's rebuild count cannot tell eases from one-shot settles.
    VibeSignpostCount(morph_started);
    _lastMorphTick = CACurrentMediaTime();
    __weak __typeof__(self) weakSelf = self;
    _morphTimer = [NSTimer timerWithTimeInterval:kMorphFrameInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf morphTick];
    }];
    [NSRunLoop.mainRunLoop addTimer:_morphTimer forMode:NSRunLoopCommonModes];
}

- (void)morphTick {
    CFTimeInterval now = CACurrentMediaTime();
    // After a stall one huge step would snap rather than ease.
    CFTimeInterval dt = clampRange(now - _lastMorphTick, 0, 0.1);
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
        _morphTimer = nil; // settled BEFORE the rebuild — see isSettled
        [self runRebuild]; // final settle always draws the exact target
        return;
    }
    // A rebuild is a full-view repaint and the tail moves imperceptibly: skip
    // frames until the fastest bar has moved about a quarter pixel.
    CGFloat vscale = _vscale ? _vscale(_size.height) : _size.height;
    _pendingRebuildPx += (float)(maxDistance * k * vscale);
    if (_pendingRebuildPx >= 0.25f) {
        VibeTallyCount(morph_eased_rebuild);
        [self runRebuild];
    }
}

@end
