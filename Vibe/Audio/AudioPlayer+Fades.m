//
//  AudioPlayer+Fades.m
//  Vibe
//

#import "AudioPlayer+Fades.h"
#import "AudioPlayerInternal.h"
#import "FadeMath.h"

// AVAudioPlayerNode smooths volume writes over 20 ms. A zero parameter is
// not yet zero output: teardown at the last write cuts that ramp mid-sample.
static const NSTimeInterval kNodeVolumeSettleSeconds = 0.020;

// The stepping loop every ramp below funnels into. Private: callers pick an
// entry point named for what they are fading, never these nine parameters.
@interface AudioPlayer (FadesPrivate)
- (void)stepRampAsync:(AVAudioPlayerNode *)node
                 step:(int)step
                 from:(float)start
                   to:(float)target
           totalSteps:(int)totalSteps
     stepMicroseconds:(uint64_t)stepMicroseconds
     fadeMilliseconds:(uint64_t)fadeMilliseconds
          preemptable:(BOOL)preemptable
           generation:(uint64_t)generation
           completion:(nullable dispatch_block_t)completion;
- (void)completeRetiredFadePair:(VibeRetiredFade *)fade;
@end

@implementation VibeRetiredFade
@end

@implementation AudioPlayer (Fades)

// Cancel the old pause intent with its ramp. Only a current completion may
// clear it later; an internal splice-removal seek explicitly carries it forward.
- (uint64_t)preemptRampsOnQueue {
    _pausePending = NO;
    return ++_rampGeneration;
}

// The one fade-stepping loop, kept non-blocking by dispatch_after on the
// player queue; every ramp below is a thin entry into it. fadeMilliseconds
// picks the curve by fade length — log at the declick minimum, equal power for
// crossfade-length fades — matching the registered stepper, so both sides of a
// crossfade ride the same curve. A preempted ramp still runs its completion,
// so completion-side bookkeeping is not lost (the seek's reschedule and
// didFinishSeeking settlement); those completions
// re-check the generation themselves and yield to the preemptor.
- (void)stepRampAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target totalSteps:(int)totalSteps stepMicroseconds:(uint64_t)stepMicroseconds fadeMilliseconds:(uint64_t)fadeMilliseconds preemptable:(BOOL)preemptable generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    if (preemptable && generation != _rampGeneration) {
        if (completion) {
            completion();
        }
        return;
    }
    node.volume = VibeFadeVolumeForFadeLength(fadeMilliseconds, start, target, step, totalSteps);
    if (step >= totalSteps) {
        if (completion) {
            if (target == 0) [self scheduleAfterSeconds:kNodeVolumeSettleSeconds block:completion];
            else completion();
        }
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:stepMicroseconds / 1000000.0 block:^{
        [weakSelf stepRampAsync:node step:step + 1 from:start to:target totalSteps:totalSteps stepMicroseconds:stepMicroseconds fadeMilliseconds:fadeMilliseconds preemptable:preemptable generation:generation completion:completion];
    }];
}

- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    [self rampNodeAsync:node step:step from:start to:target
           milliseconds:kFadeDurationMilliseconds generation:generation completion:completion];
}

- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target milliseconds:(uint64_t)milliseconds generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    if ([self leavesSamplesUntouchedOnQueue]) {
        // Unity, not the target: bit-perfect output cuts at the transport edge
        // instead. The completion keeps its later queue turn, which every
        // caller's generation checks were written against.
        node.volume = 1;
        if (completion) {
            [self scheduleAfterSeconds:0 block:completion];
        }
        return;
    }
    [self stepRampAsync:node step:step from:start to:target
             totalSteps:VibeFadeStepsForMilliseconds(milliseconds)
       stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(milliseconds)
       fadeMilliseconds:milliseconds
            preemptable:YES generation:generation completion:completion];
}

// Declick-length fade to silence for a retired node — the short retires, and
// the replacement fades preemptRetiredFadesOnQueue starts. Not preemptable:
// preemption would hard-stop the node at mid-fade volume, an audible click,
// and at this length nothing needs to cut it short. It always reaches silence,
// then runs the completion exactly once.
- (void)rampRetiredNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start milliseconds:(uint64_t)milliseconds completion:(dispatch_block_t)completion {
    [self stepRampAsync:node step:step from:start to:0
             totalSteps:VibeFadeStepsForMilliseconds(milliseconds)
       stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(milliseconds)
        fadeMilliseconds:milliseconds
            preemptable:NO generation:0 completion:completion];
}

// The crossfade-length retired fade's stepping loop. Untagged by
// _rampGeneration — a rapid skip must never cut the outgoing track's crossfade
// short — but cancellable by removing its entry from _retiredFades, after
// which the remover owns the pair's teardown.
- (void)stepRetiredFadeAsync:(VibeRetiredFade *)fade step:(int)step from:(float)start totalSteps:(int)totalSteps stepMicroseconds:(uint64_t)stepMicroseconds {
    if (![_retiredFades containsObject:fade]) {
        return; // Preempted: stop, pause, parked play or reset owns teardown.
    }
    // The last write reaches zero; the next step runs after the node's own
    // volume smoothing has settled. The same membership check cancels either.
    if (step > totalSteps) {
        [_retiredFades removeObject:fade];
        [self completeRetiredFadePair:fade];
        return;
    }
    fade.node.volume = VibeCrossfadeVolumeOverSteps(start, 0, step, totalSteps);
    NSTimeInterval delay = step == totalSteps ? kNodeVolumeSettleSeconds : stepMicroseconds / 1000000.0;
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:delay block:^{
        [weakSelf stepRetiredFadeAsync:fade step:step + 1 from:start totalSteps:totalSteps stepMicroseconds:stepMicroseconds];
    }];
}

- (void)completeRetiredFadePair:(VibeRetiredFade *)fade {
    [self detachRetiredFadePair:fade];
    if (!fade.countedAsOutput
            || fade.outputGeneration != _retiredOutputGeneration) {
        return;
    }
    fade.countedAsOutput = NO;
    if (_activeRetiredOutputCount > 0) {
        _activeRetiredOutputCount--;
    }
#if VIBE_VERBOSE_LOGGING
    if (_activeRetiredOutputCount == 0) [_levelTap endSignalOverlapAtTime:[self outputSignalRenderTimeOnQueue]];
#endif
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_OSX
    // The outgoing audio is silent: a settlement parked for a bit-perfect
    // format switch may stop the engine now.
    if (_settlementWaiter && _activeRetiredOutputCount == 0) {
        dispatch_block_t waiter = _settlementWaiter;
        _settlementWaiter = nil;
        waiter();
    }
#endif
}

// Stops and detaches a retired pair, exactly once per pair: the caller owns it
// through the natural ramp completion, by having removed the entry to cancel
// the ramp, or by retiring an already-silent pair outright. Either half may be
// nil.
- (void)detachRetiredFadePair:(VibeRetiredFade *)fade {
    // TRAP: engine identity, not just nil-ness. An unregistered declick retire
    // is unstoppable by design, so its completion can land after the iOS
    // media-services rebuild swapped _engine — detachNode: there raises,
    // because the pair was never attached to the new engine. The dead pair
    // needs no teardown; it died with its engine.
    if (fade.node && fade.node.engine == _engine) {
        [fade.node stop];
        [_engine detachNode:fade.node];
    }
    if (fade.varispeed && fade.varispeed.engine == _engine) {
        [_engine detachNode:fade.varispeed];
    }
}

// Cuts every in-flight crossfade-length retired fade down to the declick
// minimum: stop, pause, a parked play and the failure reset must not leave an
// outgoing track audible for up to the full crossfade. Skips never call this,
// so rapid skips keep the full fade-out.
- (void)preemptRetiredFadesOnQueue {
    if (_retiredFades.count == 0) {
        return;
    }
    NSArray<VibeRetiredFade *> *fades = [_retiredFades copy];
    [_retiredFades removeAllObjects];
    for (VibeRetiredFade *fade in fades) {
        if ([self leavesSamplesUntouchedOnQueue]) {
            [self completeRetiredFadePair:fade]; // a fade begun before bit-perfect output was on
            continue;
        }
        [self rampRetiredNodeAsync:fade.node step:1 from:fade.node.volume milliseconds:kFadeDurationMilliseconds completion:^{
            [self completeRetiredFadePair:fade];
        }];
    }
}

// Tears down a node and varispeed pair the caller has already pulled out of
// the live state; either may be nil. An audible pair — engine running, state
// still Playing, bit-perfect output off — fades out on its own varispeed and
// is detached once silent;
// a crossfade-length fade registers in _retiredFades so stop, pause, a parked
// play and reset can still silence it early. Paused, stopped or on a first play
// there is nothing to click, so both are torn down at once.
- (void)retireNode:(AVAudioPlayerNode *)node varispeed:(AVAudioUnitVarispeed *)varispeed milliseconds:(uint64_t)milliseconds {
    VibeRetiredFade *fade = [[VibeRetiredFade alloc] init];
    fade.node = node;
    fade.varispeed = varispeed;
    if (node && _engine.isRunning && _state == VibePlayerStatePlaying && ![self leavesSamplesUntouchedOnQueue]) {
        fade.countedAsOutput = YES;
        fade.outputGeneration = _retiredOutputGeneration;
        _activeRetiredOutputCount++;
        [self refreshOutputAudioActiveOnQueue];
        if (milliseconds <= kFadeDurationMilliseconds) {
            [self rampRetiredNodeAsync:node step:1 from:node.volume milliseconds:milliseconds completion:^{
                [self completeRetiredFadePair:fade];
            }];
            return;
        }
        [_retiredFades addObject:fade];
        [self stepRetiredFadeAsync:fade step:1 from:node.volume
                        totalSteps:VibeFadeStepsForMilliseconds(milliseconds)
                  stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(milliseconds)];
        return;
    }
    [self detachRetiredFadePair:fade];
}

@end
