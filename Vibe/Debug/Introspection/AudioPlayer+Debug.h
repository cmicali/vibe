//
//  AudioPlayer+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
//

#if DEBUG

#import "AudioPlayer.h"

@interface AudioPlayer (Debug)

// Whether --no-audio-hw's manual rendering actually engaged. The argv flag alone
// does not prove it: enableManualRenderingMode can fail, and the engine then
// opens the output device exactly as usual. Written once during the async init;
// lock-free.
- (BOOL)manualRenderingActive;

// {attachedNodes, retiredFades} for dump_health and check_invariants. A track
// change that failed to retire its node pair leaks them, which nothing else
// observes — and since a soak run is thousands of track changes, unbounded
// growth is the signal. The two are reported together because they fail apart:
// a fade entry dropped with its nodes still attached and a fade entry stranded
// after its nodes were detached are different bugs that either number alone
// cannot tell from the other.
//
// One dispatch_sync serves both. It reads on _queue, so it must not be called
// from there, and it doubles as a liveness probe for that queue: the command
// channel runs on the main thread and would otherwise never see the player
// wedged.
- (NSDictionary<NSString *, NSNumber *> *)debugEngineCounts;

@end

#endif
