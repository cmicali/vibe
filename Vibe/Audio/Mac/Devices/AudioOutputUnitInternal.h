//
//  AudioOutputUnitInternal.h
//  Vibe
//
//  The test seam: the callback and the plain struct it reads, so the host-less
//  suite can drive one IO cycle over its own buffers with a block it wrote.
//  Nothing in the app imports this.
//

#import "AudioOutputUnit.h"
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    kVibeOutputUnitMaxChannels = 8,
    // A render the engine refused because a queue-side mutation held its lock
    // is retried this many times inside the cycle before it becomes silence.
    kVibeOutputUnitRenderRetries = 3,
};

// The callback's world. Writers: the queue (`gate`, `renderBlock`, the format
// fields, between stop and start), the callback (everything else).
typedef struct {
    _Atomic int32_t gate;           // 1 between start and stop
    _Atomic int32_t inRender;       // 1 while the callback is inside the struct
    _Atomic uint64_t frames;        // engine-timeline frames rendered
    _Atomic uint32_t pendingFrames; // the block in flight
    _Atomic uint64_t dropouts;
    // The callback's cost: IO cycles the gate was open for, the nanoseconds
    // spent inside the callback over them, and the longest one. Cumulative;
    // written by the callback, outside its checked function.
    _Atomic uint64_t cycles;
    _Atomic uint64_t renderNanos;
    _Atomic uint64_t renderMaxNanos;
    _Atomic uint32_t stampVersion;  // odd while the stamp is being written
    AudioTimeStamp stamp;           // the device's stamp of the last cycle
    uint32_t channels;
    uint32_t maxFrames;             // the largest pull the block accepts; larger IO cycles are sliced
    void * _Nullable renderBlock;   // AVAudioEngineManualRenderingBlock, unretained here
    AudioBufferList * _Nullable slice; // one buffer per channel, pointed into the HAL's buffers per slice
} VibeOutputUnitState;

// Allocates the slice list for `channels` and zeroes the counters.
BOOL VibeOutputUnitStateInitialize(VibeOutputUnitState *state, uint32_t channels, uint32_t maxFrames,
                                   void * _Nullable renderBlock);
void VibeOutputUnitStateFree(VibeOutputUnitState *state);

// The HAL render callback; refCon is the VibeOutputUnitState.
OSStatus VibeOutputUnitRender(void *refCon, AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              UInt32 bus, UInt32 frameCount, AudioBufferList * _Nullable data);

NS_ASSUME_NONNULL_END
