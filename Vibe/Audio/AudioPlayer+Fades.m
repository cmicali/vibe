//
//  AudioPlayer+Fades.m
//  Vibe
//

#import "AudioPlayer+Fades.h"
#import "AudioPlayerInternal.h"
#import "FadeMath.h"

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
@end

@implementation VibeRetiredFade
@end

@implementation AudioPlayer (Fades)

// The single way to preempt the generation-tagged ramps. Clearing
// _pausePending belongs with the bump: the preempted pause fade's completion
// also clears it, but up to one fade step (~2.5ms) later, and a playPause
// inside that window would take the "cancel pending pause" path and ramp the
// preemptor's node to full instead of pausing it.
- (uint64_t)preemptRampsOnQueue {
    _pausePending = NO;
    return ++_rampGeneration;
}

// The one fade-stepping loop, kept non-blocking by dispatch_after on the
// player queue; every ramp below is a thin entry into it. fadeMilliseconds
// picks the curve by fade length — log at the declick minimum, equal power for
// crossfade-length fades — matching the registered stepper, so both sides of a
// crossfade ride the same curve. A preempted ramp still runs its completion,
// so completion-side bookkeeping is not lost (the pause fade's _pausePending
// clear, the seek's reschedule and didFinishSeeking settle); those completions
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
            completion();
        }
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepRampAsync:node step:step + 1 from:start to:target totalSteps:totalSteps stepMicroseconds:stepMicroseconds fadeMilliseconds:fadeMilliseconds preemptable:preemptable generation:generation completion:completion];
    });
}

- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    [self rampNodeAsync:node step:step from:start to:target
           milliseconds:kFadeDurationMilliseconds generation:generation completion:completion];
}

- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target milliseconds:(uint64_t)milliseconds generation:(uint64_t)generation completion:(dispatch_block_t)completion {
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
        return; // Preempted: stop, pause or reset tears the pair down.
    }
    // Registered fades are crossfade-length by construction (retireNode:), so
    // this is always the equal-power side of a crossfade; see FadeMath.h.
    fade.node.volume = VibeCrossfadeVolumeOverSteps(start, 0, step, totalSteps);
    if (step >= totalSteps) {
        [_retiredFades removeObject:fade];
        [self detachRetiredFadePair:fade];
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepRetiredFadeAsync:fade step:step + 1 from:start totalSteps:totalSteps stepMicroseconds:stepMicroseconds];
    });
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
// minimum: stop, pause and the failure reset must not leave an outgoing track
// audible for up to the full crossfade. Skips never call this, so rapid skips
// keep the full fade-out.
- (void)preemptRetiredFadesOnQueue {
    if (_retiredFades.count == 0) {
        return;
    }
    NSArray<VibeRetiredFade *> *fades = [_retiredFades copy];
    [_retiredFades removeAllObjects];
    for (VibeRetiredFade *fade in fades) {
        [self rampRetiredNodeAsync:fade.node step:1 from:fade.node.volume milliseconds:kFadeDurationMilliseconds completion:^{
            [self detachRetiredFadePair:fade];
        }];
    }
}

// Tears down a node and varispeed pair the caller has already pulled out of
// the live state; either may be nil. An audible pair — engine running, state
// still Playing — fades out on its own varispeed and is detached once silent;
// a crossfade-length fade registers in _retiredFades so stop, pause and reset
// can still silence it early. Paused, stopped or on a first play there is
// nothing to click, so both are torn down at once.
- (void)retireNode:(AVAudioPlayerNode *)node varispeed:(AVAudioUnitVarispeed *)varispeed milliseconds:(uint64_t)milliseconds {
    VibeRetiredFade *fade = [[VibeRetiredFade alloc] init];
    fade.node = node;
    fade.varispeed = varispeed;
    if (node && _engine.isRunning && _state == VibePlayerStatePlaying) {
        if (milliseconds <= kFadeDurationMilliseconds) {
            [self rampRetiredNodeAsync:node step:1 from:node.volume milliseconds:milliseconds completion:^{
                [self detachRetiredFadePair:fade];
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
