//
//  AudioMasterBusInternal.h
//  Vibe
//
//  The master bus's layout. The render (AudioMasterBus.m) and the player
//  queue's side of it (AudioPlayer+Pipeline.m) both read it.
//

#import "AudioMasterBus.h"
#import "AudioFX+Pipeline.h"
#import "AudioLevelMeter.h"
#import "AudioVarispeed.h"
#import "VibeMacros.h"
#include <stdatomic.h>
#include <unistd.h>

// A render already inside the pipeline leaves within a block's time; the
// wait is bounded, as the output unit's stop is.
static const useconds_t kRenderLeaveSpinMicroseconds = 200;
static const int kRenderLeaveSpinLimit = 500; // 100 ms

// What the audio thread reads. Writers: the queue (the pointers, with the
// output stopped or withdrawn before the render is waited out; the gate,
// the flags and the format's two scalars, atomics so a format change under
// a late render tears nothing), the render (the counters and inRender).
struct VibeMasterBus {
    _Atomic int32_t gate;            // 1 while the output may render
    // The pipeline's door: 1 while a render is inside. A second render finding
    // it taken (a callback outlived its unit's bounded stop while the next
    // unit began) renders silence and touches nothing. TRAP: only the render
    // that took the door releases it; a flag any render could clear lets the
    // new unit's first callback clear the stuck one's, and the drain frees the
    // bus that render is still mixing.
    _Atomic int32_t inRender;
    _Atomic uint64_t refusedRenders; // renders the door turned away; a soak holds it at zero
    _Atomic uint64_t frames;         // the output timeline: frames rendered
    _Atomic uint32_t pendingFrames;  // the slice in flight
    _Atomic int32_t silent;          // --silent: the volume's target is 0, so the meter sees the signal and the device zeros
    // The output volume: the queue's target gain, and the gain the render last
    // landed on, which it ramps from. volumeSnap, raised by every output
    // start, lands the next slice on the target instead: nothing sounded
    // since the last one, so a start plays at the volume it was left at.
    _Atomic float volume;
    _Atomic int32_t volumeSnap;
    float volumeApplied;
    _Atomic(VibeVoiceMix *) mix;     // the bus; NULL until the first settlement
    _Atomic(VibeFXChain *) chain;    // the FX segment while it is connected; NULL otherwise
    _Atomic(VibeLevelMeter *) meter; // the equalizer's, while wanted
    _Atomic double hostTicksPerFrame;
    _Atomic uint32_t channels;       // the output's, 1 or 2: what a slice carries; every output unit the app makes is stereo
    // The varispeed: hosted for ordinary playback on macOS, a bit-perfect
    // pass-through at zero pitch (AudioVarispeed.h).
    _Atomic(VibeVarispeed *) varispeed; // NULL without one
    // Debug builds only. A test's stuck render: while set, a render blocks
    // inside the pipeline after reading the bus; rendersHeld counts them.
    _Atomic int32_t holdRenderInside;
    _Atomic int32_t rendersHeld;
};

// Whether a render is inside the pipeline right now. Inline, because the
// queue polls it while it waits for the render to leave.
static inline BOOL VibeMasterBusRenderInside(VibeMasterBus *master) {
    return atomic_load_explicit(&master->inRender, memory_order_seq_cst) != 0;
}

VIBE_REALTIME_CHECKED_BEGIN
static inline uint32_t VibeMasterBusChannels(const VibeMasterBus *master) CA_REALTIME_API {
    return atomic_load_explicit(&master->channels, memory_order_relaxed);
}
VIBE_REALTIME_END
