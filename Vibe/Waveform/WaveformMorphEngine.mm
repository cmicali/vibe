//
//  WaveformMorphEngine.mm
//  Vibe
//

#import "WaveformMorphEngine.h"

#include <cmath>

// The time constant of the exponential ease toward the target samples. Each
// frame the displayed bars cover a dt-scaled fraction of the remaining
// distance, settling to about 95% in roughly 3τ, or 0.2s.
static const CFTimeInterval kMorphTau = 0.07;
// The convergence threshold, in the caller's normalized sample units.
static const float kMorphEpsilon = 0.002f;
static const NSTimeInterval kMorphFrameInterval = 1.0 / 60.0;

@implementation WaveformMorphEngine {
    // What is on screen against where it is heading, in the caller's sample
    // layout.
    std::vector<float> _displayedSamples;
    std::vector<float> _targetSamples;
    // targetScratchWithCount:'s reusable buffer. It is swapped with
    // _targetSamples when the target moves, and then holds the stale target
    // until the next call overwrites it.
    std::vector<float> _scratchSamples;
    CGSize _size;
    BOOL _hasWaveform;   // NO = the zero target means "empty", drawn as nothing rather than hairline bars
    // What the current target was built from, and its length: the fast-path
    // gate in updateTargetForSize:. The pointer is compare-only and may dangle
    // once the caller's waveform is released.
    const void *_lastTargetIdentity;
    NSUInteger _lastTargetCount;
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
    }
    return self;
}

- (void)dealloc {
    // The timer's firing block holds the engine weakly. Without this it would
    // keep firing on the run loop forever.
    [_morphTimer invalidate];
}

// The declaration documents the rationale for each branch.
- (void)updateTargetForSize:(CGSize)size
                   identity:(const void *)identity
                      count:(NSUInteger)count
                       fill:(void (^)(std::vector<float> &target))fill {
    if (identity == _lastTargetIdentity && count == _lastTargetCount) {
        // The target is unchanged, so do not touch the scratch: after a commit
        // it holds the stale target, and comparing against it would morph back
        // to it. Only a geometry change matters here.
        BOOL geometryChanged = !CGSizeEqualToSize(size, _size);
        _size = size;
        if (geometryChanged) {
            [self runRebuild];
        }
        return;
    }
    _lastTargetIdentity = identity;
    _lastTargetCount = count;
    std::vector<float> &target = [self targetScratchWithCount:count];
    if (identity) {
        fill(target);
    } else {
        std::fill(target.begin(), target.end(), 0.0f);
    }
    [self commitTargetForSize:size hasWaveform:(identity != NULL)];
}

- (std::vector<float> &)targetScratchWithCount:(NSUInteger)count {
    if (_scratchSamples.size() != count) {
        _scratchSamples.resize(count); // new elements value-init to 0
    }
    return _scratchSamples;
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
    // Draw the notch this frame — the timer's first tick would otherwise ease
    // it partway back before it was ever seen at zero.
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

// updateTargetForSize:'s slow path; the branch rationale lives on that
// declaration. This is internal, and the scratch must be freshly filled before
// it runs, because after a commit it holds the stale target.
- (void)commitTargetForSize:(CGSize)size hasWaveform:(BOOL)hasWaveform {
    BOOL geometryChanged = !CGSizeEqualToSize(size, _size);
    _size = size;
    BOOL hasWaveformChanged = (_hasWaveform != hasWaveform);
    _hasWaveform = hasWaveform;
    if (_displayedSamples.size() != _scratchSamples.size()) {
        // A first draw, or a bar-count change, so start collapsed.
        _displayedSamples.assign(_scratchSamples.size(), 0.0f);
        geometryChanged = YES;
    }
    BOOL targetChanged = (_scratchSamples != _targetSamples);
    if (!targetChanged && !geometryChanged && !hasWaveformChanged) {
        return;
    }
    if (targetChanged) {
        std::swap(_targetSamples, _scratchSamples);
    }
    // A hasWaveform flip on its own. The samples are identical, so no morph
    // will run, but the hairline floor has changed, so redraw in place.
    if (geometryChanged || (hasWaveformChanged && !targetChanged)) {
        [self runRebuild];
    }
    if (targetChanged) {
        [self startMorphTimer];
    }
}

- (void)runRebuild {
    _pendingRebuildPx = 0;
    if (_rebuild) {
        _rebuild();
    }
}

// Eases the displayed samples toward the target, converging in about 3τ. It
// runs on the main run loop's common modes, so that morphs do not freeze
// during menu tracking or a live resize.
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
    // Clamp dt. After a stall — a debugger pause, an occluded window — one
    // huge step would snap the morph rather than ease it.
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
        _morphTimer = nil; // settled BEFORE the rebuild — see isSettled
        [self runRebuild]; // final settle always draws the exact target
        return;
    }
    // Each rebuild is a full-view repaint, and the exponential tail spends
    // many frames moving imperceptibly, so skip frames until the fastest bar
    // has accumulated about a quarter of a pixel of motion.
    CGFloat vscale = _vscale ? _vscale(_size.height) : _size.height;
    _pendingRebuildPx += (float)(maxDistance * k * vscale);
    if (_pendingRebuildPx >= 0.25f) {
        [self runRebuild];
    }
}

@end
