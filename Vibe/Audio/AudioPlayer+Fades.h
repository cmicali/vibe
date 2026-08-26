//
//  AudioPlayer+Fades.h
//  Vibe
//
//  Every volume ramp the player performs: the pause and resume fades, the
//  crossfade's fade-in, and the fade-out of a node the play path has retired.
//  The curves and the step cadence are FadeMath.h, shared with AudioFX's send
//  gates; what lives here is the stepping loop that walks them without
//  blocking the player queue.
//
//  TRAP: two liveness mechanisms, and confusing them is the bug this file
//  exists to keep visible.
//
//  - **Generation-tagged ramps** (preemptRampsOnQueue, and the ramps passing
//    preemptable:YES) belong to the CURRENT node. A newer operation — pause,
//    resume, seek, skip, device switch — bumps the generation and the old
//    ramp stops stepping the volume, though it still runs its completion so
//    that completion-side bookkeeping is not lost.
//  - **Registered retired fades** (_retiredFades) belong to a node already
//    pulled out of the live state. Membership in the array IS the ramp's
//    liveness, so removing an entry cancels it and the remover owns the
//    pair's teardown. A retired fade is deliberately NOT preemptable by an
//    ordinary generation bump: a second skip inside the fade window would
//    otherwise stop the node at mid-fade volume, which clicks. Only stop,
//    pause, a parked play and the failure reset silence one early, through
//    preemptRetiredFadesOnQueue.
//
//  Everything here runs on the player queue.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Fades)

- (uint64_t)preemptRampsOnQueue;

// A generation-tagged ramp on the current node, at the player's declick length.
- (void)rampNodeAsync:(AVAudioPlayerNode *)node
                 step:(int)step
                 from:(float)start
                   to:(float)target
           generation:(uint64_t)generation
           completion:(nullable dispatch_block_t)completion;

// The same ramp at a length the caller picked, for the one caller that has to:
// the crossfade's fade-in, which must match the fade-out playOnQueue: started.
- (void)rampNodeAsync:(AVAudioPlayerNode *)node
                 step:(int)step
                 from:(float)start
                   to:(float)target
         milliseconds:(uint64_t)milliseconds
           generation:(uint64_t)generation
           completion:(nullable dispatch_block_t)completion;

- (void)retireNode:(nullable AVAudioPlayerNode *)node
         varispeed:(nullable AVAudioUnitVarispeed *)varispeed
      milliseconds:(uint64_t)milliseconds;
- (void)preemptRetiredFadesOnQueue;

@end

NS_ASSUME_NONNULL_END
