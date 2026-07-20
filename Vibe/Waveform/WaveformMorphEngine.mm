//
//  WaveformMorphEngine.mm
//  Vibe
//

#import "WaveformMorphEngine.h"

#include <cmath>

// Time constant of the exponential ease toward the target samples: each
// frame the displayed bars cover a dt-scaled fraction of the remaining
// distance, settling (~95%) in about 3τ ≈ 0.2s.
static const CFTimeInterval kMorphTau = 0.07;
// Convergence threshold in the caller's normalized sample units.
static const float kMorphEpsilon = 0.002f;
static const NSTimeInterval kMorphFrameInterval = 1.0 / 60.0;

@implementation WaveformMorphEngine {
    // What's on screen vs. where it's heading, in the caller's sample layout.
    std::vector<float> _displayedSamples;
    std::vector<float> _targetSamples;
    // targetScratchWithCount:'s reusable buffer — swapped with _targetSamples
    // when the target moves (it then holds the stale target until the next
    // call overwrites it).
    std::vector<float> _scratchSamples;
    CGSize _size;
    BOOL _hasWaveform;   // NO = the zero target means "empty", drawn as nothing rather than hairline bars
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
    // The timer's firing block holds the engine weakly; without this it
    // would keep firing on the run loop forever.
    [_morphTimer invalidate];
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

- (CGSize)size {
    return _size;
}

- (BOOL)hasWaveform {
    return _hasWaveform;
}

- (BOOL)isSettled {
    return _morphTimer == nil;
}

// The rationale for each branch is documented on the declaration.
- (void)commitTargetForSize:(CGSize)size hasWaveform:(BOOL)hasWaveform {
    BOOL geometryChanged = !CGSizeEqualToSize(size, _size);
    _size = size;
    BOOL hasWaveformChanged = (_hasWaveform != hasWaveform);
    _hasWaveform = hasWaveform;
    if (_displayedSamples.size() != _scratchSamples.size()) {
        // First draw (or a bar-count change): start collapsed.
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
    // hasWaveform flip alone: the samples are identical so no morph will run,
    // but the hairline floor changed — redraw in place.
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

// Ease displayed toward target, converging in ~3τ. Runs on the main run
// loop's common modes so morphs don't freeze during menu tracking or a
// live resize.
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
        _morphTimer = nil; // settled BEFORE the rebuild — see isSettled
        [self runRebuild]; // final settle always draws the exact target
        return;
    }
    // Each rebuild is a full-view repaint, and the exponential tail spends
    // many frames moving imperceptibly — skip frames until the fastest bar
    // has accumulated ~a quarter pixel of motion.
    CGFloat vscale = _vscale ? _vscale(_size.height) : _size.height;
    _pendingRebuildPx += (float)(maxDistance * k * vscale);
    if (_pendingRebuildPx >= 0.25f) {
        [self runRebuild];
    }
}

@end
