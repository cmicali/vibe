//
//  AudioOutputUnitInternal.h
//  Vibe
//
//  The test seam: the callback and the plain struct it reads, so the host-less
//  suite can drive one IO cycle over its own buffers with a render proc it
//  wrote. Nothing in the app imports this.
//

#import "AudioOutputUnit.h"
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

// The callback's world. Writers: the queue (`gate`, the proc and the channel
// count, between stop and start), the running listener (`stoppedBySystem`),
// the callback (everything else).
typedef struct {
    _Atomic int32_t gate;           // 1 between start and stop
    _Atomic int32_t inRender;       // 1 while the callback is inside the struct
    // iOS: 1 while the system holds the unit stopped under an open gate, as
    // an interruption does. Written by the unit's IsRunning listener.
    _Atomic int32_t stoppedBySystem;
    _Atomic uint64_t dropouts;
    // The callback's cost: IO cycles the gate was open for, the nanoseconds
    // spent inside the callback over them, and the longest one. Cumulative;
    // written by the callback, outside its checked function.
    _Atomic uint64_t cycles;
    _Atomic uint64_t renderNanos;
    _Atomic uint64_t renderMaxNanos;
    uint32_t channels;
    VibeOutputRenderProc _Nullable renderProc;
    void * _Nullable renderRefCon;
} VibeOutputUnitState;

// Records the proc for `channels`; NO for a format without any.
BOOL VibeOutputUnitStateInitialize(VibeOutputUnitState *state, uint32_t channels,
                                   VibeOutputRenderProc _Nullable renderProc, void * _Nullable renderRefCon);

// The HAL render callback; refCon is the VibeOutputUnitState.
OSStatus VibeOutputUnitRender(void *refCon, AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              UInt32 bus, UInt32 frameCount, AudioBufferList * _Nullable data);

// The unit's own HAL calls, made on its queue. The host-less suite replaces
// them to make a device slow to start, or refuse, without opening one.
@interface AudioOutputUnit (HAL)
@property (nonatomic, readonly) VibeOutputUnitState *state;
- (void)halConfigureFormat:(AVAudioFormat *)format renderProc:(VibeOutputRenderProc _Nullable)renderProc
                    refCon:(void * _Nullable)refCon;
- (OSStatus)halStartUnit;
@end

// Zeroes the dropout and callback-cost counters. Any thread; a cycle in
// flight lands in the new count, which a measurement tolerates.
void VibeOutputUnitStateClearCounters(VibeOutputUnitState *state);

NS_ASSUME_NONNULL_END
