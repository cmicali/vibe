//
//  AudioPlayer+Pipeline.m
//  Vibe
//

#import "AudioPlayer+Pipeline.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#import "OutputFormatRules.h"
#endif
#if DEBUG
#import "VibeManualRenderPump.h"
#import "AudioPlayer+Debug.h"
#endif
#import <Accelerate/Accelerate.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <unistd.h>

// Give the next track time to open before releasing the idle output.
static const NSTimeInterval kOutputIdleStopDelaySeconds = 6.0;
// A send's tail still ringing at the delay keeps the output, re-checked at
// this interval for at most the chain's longest tail past the delay: a
// released send rests on its own before that, and one held through the
// pause has nothing left to ring by then.
static const NSTimeInterval kOutputIdleStopTailIntervalSeconds = 1.0;
// A system stop's verdict (an interruption's pause, a route's recovery) lands
// within milliseconds of it; past this, none is coming.
static const NSTimeInterval kSystemStopVerdictSeconds = 1.0;
// An output start holding the player queue longer than this is worth a line
// even in stable builds.
static const NSTimeInterval kSlowOutputStartLogThresholdSeconds = 0.25;
// A render already inside the pipeline leaves within a block's time; the
// wait is bounded, as the output unit's stop is.
static const useconds_t kRenderLeaveSpinMicroseconds = 200;
static const int kRenderLeaveSpinLimit = 500; // 100 ms

#pragma mark - The master bus

// One hosting of the varispeed: the unit, the rings its engage and
// disengage need, and whether it is in the chain, freed together once the
// render was seen outside them; the master bus points at the current one.
typedef struct {
    AudioUnit unit;
    VibeMasterBus *master;           // the stamp and the channels the input callback serves
    VibeVoiceMix *mix;               // the bus the input callback serves: the render's, written before each pull, so a slice reads one bus
    uint32_t latency;                // the unit's declared latency, in frames at the bus rate
    uint32_t quality;                // kAudioUnitProperty_RenderQuality, read back at host
    _Atomic int32_t engaged;         // 1 while the unit is in the chain; the render's, set at a slice boundary
    // A ring of bus frames, in bus time, that the render alone touches and
    // writes only around a transition: while an engage is being prepared it
    // records the frames the direct path plays, which then prime the unit's
    // filter; while the unit is in the chain its input records what it
    // pulled, which the disengage replays. At zero pitch and settled, no
    // frame is copied.
    float *recent[2];
    uint32_t recentMask;
    uint64_t recentWritten;
    uint64_t serveNext;              // a cursor into the ring, for the priming and the replay
    uint32_t preparing;              // 1 while the direct path records history for the engage
    uint64_t prepareStart;           // recentWritten when the preparation began
    uint32_t primeRemaining;         // history frames the varispeed's input still serves before the bus
    uint32_t replayRemaining;        // pulled-ahead frames the direct path still plays before the bus
    float *scratch[2];               // the priming render's discarded output, recentMask + 1 frames
} VibeVarispeedHost;

// What the audio thread reads. Writers: the queue (the pointers, with the
// output stopped or withdrawn before the render is waited out; the gate,
// the flags and the format's two scalars, atomics so a format change under
// a late render tears nothing), the render (the counters, the stamp and
// inRender).
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
    AudioTimeStamp stamp;            // the slice's own stamp, which the bus reads through the varispeed's pull
    _Atomic double hostTicksPerFrame;
    _Atomic uint32_t channels;       // the output's, 1 or 2: what a slice carries; every output unit the app makes is stereo
    // The varispeed: hosted for ordinary playback on macOS, and in the chain
    // only while the pitch is off zero. The queue writes `wanted` and the
    // rate; the render engages and disengages the unit at a slice boundary
    // and owns the hosting's `engaged` (VibeMasterBusRenderSource says how).
    _Atomic(VibeVarispeedHost *) varispeed; // the current hosting; NULL without one
    _Atomic int32_t varispeedWanted;
    _Atomic int32_t varispeedRateMilli; // the ratio × 1000, so the render does integer arithmetic
    _Atomic uint64_t varispeedRenders;
    _Atomic uint64_t varispeedHistoryWrites; // ring writes: none at zero pitch outside a transition
#if DEBUG
    // A test's stuck render: while set, a render blocks inside the pipeline
    // after reading the bus; rendersHeld counts them.
    _Atomic int32_t holdRenderInside;
    _Atomic int32_t rendersHeld;
#endif
};

// A stereo slice list the render builds on its stack.
typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} VibeMasterBusStereoList;

// The calls the compiler cannot check: the varispeed's render, which
// AudioToolbox documents as the render thread's own entry point and
// attributes with nothing, the volume's vDSP, which Accelerate attributes
// with nothing either, and, in debug builds, the sleep of a test's render
// held inside the pipeline.
VIBE_REALTIME_UNCHECKED_BEGIN
static inline OSStatus VibeMasterBusRenderVarispeed(VibeMasterBus *master, AudioUnit varispeed, const AudioTimeStamp *stamp,
                                                    UInt32 frames, AudioBufferList *data) CA_REALTIME_API {
    AudioUnitRenderActionFlags flags = 0;
    atomic_fetch_add_explicit(&master->varispeedRenders, 1, memory_order_relaxed);
    return AudioUnitRender(varispeed, &flags, stamp, 0, frames, data);
}
// `start` onward by `step` per frame; a step of 0 scales exactly.
static inline void VibeMasterBusRamp(float *samples, float start, float step, UInt32 frames) CA_REALTIME_API {
    vDSP_vrampmul(samples, 1, &start, &step, samples, 1, frames);
}
#if DEBUG
static inline void VibeMasterBusHoldWait(void) CA_REALTIME_API {
    usleep(kRenderLeaveSpinMicroseconds);
}
#endif
VIBE_REALTIME_END

// Everything the audio thread does; the checked region makes a blocking call a
// build error.
VIBE_REALTIME_CHECKED_BEGIN
static inline uint32_t VibeMasterBusChannels(const VibeMasterBus *master) CA_REALTIME_API {
    return atomic_load_explicit(&master->channels, memory_order_relaxed);
}

static inline double VibeMasterBusTicksPerFrame(const VibeMasterBus *master) CA_REALTIME_API {
    return atomic_load_explicit(&master->hostTicksPerFrame, memory_order_relaxed);
}

static inline void VibeMasterBusZero(AudioBufferList *data, UInt32 offset, UInt32 frames) CA_REALTIME_API {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset((float *)data->mBuffers[b].mData + offset, 0, frames * sizeof(float));
        }
    }
}

// `frames` of `data`, from `offset`, as a list of the bus's channels.
static inline VibeMasterBusStereoList VibeMasterBusSubList(const VibeMasterBus *master, AudioBufferList *data, UInt32 offset,
                                                           UInt32 frames) CA_REALTIME_API {
    uint32_t channels = VibeMasterBusChannels(master);
    VibeMasterBusStereoList list = { channels, {{0}} };
    for (UInt32 c = 0; c < channels; c++) {
        list.mBuffers[c].mNumberChannels = 1;
        list.mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        list.mBuffers[c].mData = (float *)data->mBuffers[c].mData + offset;
    }
    return list;
}

// The last `frames` of `data` into the hosting's ring, in bus time.
static inline void VibeMasterBusRecord(VibeVarispeedHost *host, const AudioBufferList *data, UInt32 frames) CA_REALTIME_API {
    uint32_t capacity = host->recentMask + 1;
    if (!host->recent[0] || frames == 0) {
        return;
    }
    uint32_t channels = VibeMasterBusChannels(host->master);
    UInt32 skip = frames > capacity ? frames - capacity : 0;
    UInt32 count = frames - skip;
    uint32_t index = (uint32_t)(host->recentWritten + skip) & host->recentMask;
    UInt32 first = count < capacity - index ? count : capacity - index;
    for (uint32_t c = 0; c < channels; c++) {
        const float *source = data->mBuffers[c].mData;
        if (!source) {
            continue;
        }
        source += skip;
        memcpy(host->recent[c] + index, source, first * sizeof(float));
        if (count > first) {
            memcpy(host->recent[c], source + first, (count - first) * sizeof(float));
        }
    }
    host->recentWritten += frames;
    atomic_fetch_add_explicit(&host->master->varispeedHistoryWrites, 1, memory_order_relaxed);
}

// `frames` of the ring from `start` (bus time) into `data` at `offset`.
static inline void VibeMasterBusRecall(const VibeVarispeedHost *host, uint64_t start, UInt32 frames, AudioBufferList *data,
                                       UInt32 offset) CA_REALTIME_API {
    if (!host->recent[0]) {
        return; // never asked without a ring: the counters it serves are set only with one
    }
    uint32_t capacity = host->recentMask + 1;
    uint32_t index = (uint32_t)start & host->recentMask;
    UInt32 first = frames < capacity - index ? frames : capacity - index;
    uint32_t channels = VibeMasterBusChannels(host->master);
    for (uint32_t c = 0; c < channels; c++) {
        float *base = data->mBuffers[c].mData;
        if (!base) {
            continue;
        }
        memcpy(base + offset, host->recent[c] + index, first * sizeof(float));
        if (frames > first) {
            memcpy(base + offset + first, host->recent[c], (frames - first) * sizeof(float));
        }
    }
}

// The varispeed's input: the bus, for whatever count the unit asks, stamped
// with the slice's own stamp — the unit forwards a stamp of its own whose
// host time is not the cycle's. While the engage primes the unit, the last
// frames heard come first, so its filter holds what the listener already
// heard instead of silence.
static OSStatus VibeMasterBusVarispeedInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *stamp,
                                            UInt32 bus, UInt32 frames, AudioBufferList *data) CA_REALTIME_API {
    VibeVarispeedHost *host = refCon;
    VibeMasterBus *master = host->master;
    VibeVoiceMix *mix = host->mix;
    if (!mix || !data || data->mNumberBuffers < VibeMasterBusChannels(master)) {
        if (data) {
            VibeMasterBusZero(data, 0, frames);
        }
        if (flags) {
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }
    UInt32 offset = 0;
    if (host->primeRemaining) {
        offset = frames < host->primeRemaining ? frames : host->primeRemaining;
        VibeMasterBusRecall(host, host->serveNext, offset, data, 0);
        host->serveNext += offset;
        host->primeRemaining -= offset;
    }
    if (offset == frames) {
        return noErr;
    }
    VibeMasterBusStereoList rest = VibeMasterBusSubList(master, data, offset, frames - offset);
    BOOL silence = NO;
    OSStatus status = VibeVoiceBusRender(mix, &silence, &master->stamp, frames - offset, (AudioBufferList *)&rest);
    VibeMasterBusRecord(host, (AudioBufferList *)&rest, frames - offset);
    if (silence && offset == 0 && flags) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return status;
}

// Puts the varispeed in the chain without a click: the unit is cold — its
// filter holds zeros, or the frames of an earlier engagement — so it is
// rendered once for its discarded outputs with its input served the frames
// the direct path just played (twice its latency, recorded while the engage
// was prepared, so the filter's window is real audio) and then the bus,
// exactly enough that its next output frame is the bus frame the direct
// path would have played. At the ratio r the unit pulls r inputs per
// output, so (history + latency) inputs take (history + latency) / r
// outputs; the fractional frame this leaves is inaudible. `next` is the
// stamp of the slice the unit renders first.
static void VibeMasterBusEngageVarispeed(VibeVarispeedHost *host, const AudioTimeStamp *next) CA_REALTIME_API {
    VibeMasterBus *master = host->master;
    uint32_t capacity = host->recentMask + 1;
    uint32_t latency = host->latency;
    uint64_t recorded = host->recentWritten - host->prepareStart;
    uint64_t available = recorded < capacity ? recorded : capacity;
    uint32_t history = (uint32_t)(available < 2 * latency ? available : 2 * latency);
    host->preparing = 0;
    int32_t rateMilli = atomic_load_explicit(&master->varispeedRateMilli, memory_order_relaxed);
    if (rateMilli <= 0) {
        rateMilli = 1000;
    }
    uint32_t outputs = (uint32_t)(((uint64_t)(history + latency) * 1000 + (uint64_t)rateMilli - 1) / (uint64_t)rateMilli);
    if (outputs > capacity) {
        outputs = capacity;
    }
    host->replayRemaining = 0;
    host->serveNext = host->recentWritten - history;
    host->primeRemaining = history;
    if (outputs) {
        uint32_t channels = VibeMasterBusChannels(master);
        VibeMasterBusStereoList discard = { channels, {{0}} };
        for (uint32_t c = 0; c < channels; c++) {
            discard.mBuffers[c].mNumberChannels = 1;
            discard.mBuffers[c].mDataByteSize = outputs * (UInt32)sizeof(float);
            discard.mBuffers[c].mData = host->scratch[c];
        }
        // Stamped just before the slice it precedes, so the unit sees one
        // continuous timeline: a stamp that stepped back would read as a
        // discontinuity.
        AudioTimeStamp priming = *next;
        priming.mSampleTime -= outputs;
        if (priming.mFlags & kAudioTimeStampHostTimeValid) {
            priming.mHostTime -= (UInt64)(outputs * VibeMasterBusTicksPerFrame(master));
        }
        VibeMasterBusRenderVarispeed(master, host->unit, &priming, outputs, (AudioBufferList *)&discard);
    }
    host->primeRemaining = 0;
    atomic_store_explicit(&host->engaged, 1, memory_order_release);
}

// Takes the varispeed out of the chain without a skip: the unit has pulled
// its latency's worth of bus frames it has not output yet, so the direct
// path plays those from the ring before the bus, at the bus's own pace.
static void VibeMasterBusDisengageVarispeed(VibeVarispeedHost *host) CA_REALTIME_API {
    uint32_t capacity = host->recentMask + 1;
    uint64_t available = host->recentWritten < capacity ? host->recentWritten : capacity;
    uint32_t replay = (uint32_t)(available < host->latency ? available : host->latency);
    host->primeRemaining = 0;
    host->serveNext = host->recentWritten - replay;
    host->replayRemaining = replay;
    atomic_store_explicit(&host->engaged, 0, memory_order_release);
}

// The source segment into `list`: the bus through the varispeed while the
// pitch is off zero, the bus straight in otherwise — no unit rendered, no
// delay, no copy, the samples the bus produced. A change of mind is applied
// at slice boundaries: leaving zero, the direct path first plays and records
// twice the unit's latency of frames (the unit's history), then primes and
// engages the unit at the end of that slice; returning to zero disengages
// at the slice's start and replays what the unit had pulled ahead.
static OSStatus VibeMasterBusRenderSource(VibeMasterBus *master, VibeVoiceMix *mix, const AudioTimeStamp *stamp, UInt32 frames,
                                          AudioBufferList *list) CA_REALTIME_API {
    // Read once: a re-host swaps the pointer, and this render finishes
    // inside the hosting it read — and the unit's pulls read the bus this
    // slice read, never the atomic again.
    VibeVarispeedHost *host = atomic_load_explicit(&master->varispeed, memory_order_seq_cst);
    if (host) {
        host->mix = mix;
    }
    BOOL wanted = host && atomic_load_explicit(&master->varispeedWanted, memory_order_seq_cst);
    BOOL engaged = host && atomic_load_explicit(&host->engaged, memory_order_relaxed) != 0;
    if (!wanted && engaged) {
        VibeMasterBusDisengageVarispeed(host);
        engaged = NO;
    }
    if (engaged) {
        return VibeMasterBusRenderVarispeed(master, host->unit, stamp, frames, list);
    }
    UInt32 offset = 0;
    OSStatus status = noErr;
    if (host && host->replayRemaining) {
        offset = frames < host->replayRemaining ? frames : host->replayRemaining;
        VibeMasterBusRecall(host, host->serveNext, offset, list, 0);
        host->serveNext += offset;
        host->replayRemaining -= offset;
    }
    if (offset < frames) {
        VibeMasterBusStereoList rest = VibeMasterBusSubList(master, list, offset, frames - offset);
        BOOL silence = NO;
        status = VibeVoiceBusRender(mix, &silence, stamp, frames - offset, (AudioBufferList *)&rest);
    }
    if (!wanted) {
        if (host) {
            host->preparing = 0;
        }
        return status;
    }
    // Preparing the engage: what was heard is the unit's history, and once
    // twice its latency of it is recorded the unit joins at the next slice.
    if (!host->preparing) {
        host->preparing = 1;
        host->prepareStart = host->recentWritten;
    }
    VibeMasterBusRecord(host, list, frames);
    if (host->recentWritten - host->prepareStart >= 2 * (uint64_t)host->latency) {
        AudioTimeStamp next = *stamp;
        next.mSampleTime += frames;
        if (next.mFlags & kAudioTimeStampHostTimeValid) {
            next.mHostTime += (UInt64)(frames * VibeMasterBusTicksPerFrame(master));
        }
        VibeMasterBusEngageVarispeed(host, &next);
    }
    return status;
}

// After the meter, so the equalizer shows the signal whatever the volume. A
// change ramps linearly across one slice, so a drag cannot zipper. Settled at
// 0 it writes zeros rather than a product, which a NaN would survive.
static void VibeMasterBusApplyVolume(VibeMasterBus *master, AudioBufferList *list, uint32_t channels,
                                     UInt32 frames) CA_REALTIME_API {
    float target = atomic_load_explicit(&master->silent, memory_order_relaxed)
            ? 0.0f : atomic_load_explicit(&master->volume, memory_order_relaxed);
    if (atomic_exchange_explicit(&master->volumeSnap, 0, memory_order_acquire)) {
        master->volumeApplied = target;
    }
    float from = master->volumeApplied;
    if (from == target && target == 1.0f) {
        return;
    }
    if (from == target && target == 0.0f) {
        VibeMasterBusZero(list, 0, frames);
        return;
    }
    float step = (target - from) / (float)frames;
    for (uint32_t c = 0; c < channels; c++) {
        VibeMasterBusRamp(list->mBuffers[c].mData, from, step, frames);
    }
    master->volumeApplied = target;
}

// One slice, no larger than a hosted unit accepts, straight into `data` at
// `offset`.
static OSStatus VibeMasterBusRenderSlice(VibeMasterBus *master, const AudioTimeStamp *hostStamp, UInt32 offset, UInt32 frames,
                                         AudioBufferList *data) CA_REALTIME_API {
    VibeMasterBusStereoList slice = VibeMasterBusSubList(master, data, offset, frames);
    uint32_t channels = slice.mNumberBuffers;
    AudioBufferList *list = (AudioBufferList *)&slice;
    // The stamp every stage sees: sample time on the output timeline, host
    // time from the output unit's cycle when it has one, advanced for a later
    // slice of it.
    uint64_t rendered = atomic_load_explicit(&master->frames, memory_order_relaxed);
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = (Float64)rendered;
    stamp.mFlags = kAudioTimeStampSampleTimeValid;
    if (hostStamp && (hostStamp->mFlags & kAudioTimeStampHostTimeValid)) {
        stamp.mHostTime = hostStamp->mHostTime + (UInt64)(offset * VibeMasterBusTicksPerFrame(master));
        stamp.mFlags |= kAudioTimeStampHostTimeValid;
    }
    master->stamp = stamp;
    atomic_store_explicit(&master->pendingFrames, frames, memory_order_release);
    OSStatus status = noErr;
    // Every pointer the queue withdraws is loaded sequentially consistent,
    // after the door's CAS: either the withdrawal is seen here, or the
    // queue's wait sees this render inside, whether or not the gate is closed.
    VibeVoiceMix *mix = atomic_load_explicit(&master->mix, memory_order_seq_cst);
#if DEBUG
    // The held render has read the bus: whatever the queue withdraws now,
    // this render is inside it until the hold lifts.
    if (atomic_load_explicit(&master->holdRenderInside, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&master->rendersHeld, 1, memory_order_seq_cst);
        while (atomic_load_explicit(&master->holdRenderInside, memory_order_relaxed)) {
            VibeMasterBusHoldWait();
        }
        atomic_fetch_sub_explicit(&master->rendersHeld, 1, memory_order_seq_cst);
    }
#endif
    if (!mix) {
        VibeMasterBusZero(list, 0, frames);
        VibeVarispeedHost *host = atomic_load_explicit(&master->varispeed, memory_order_seq_cst);
        if (host) {
            atomic_store_explicit(&host->engaged, 0, memory_order_relaxed);
            host->replayRemaining = 0;
        }
    }
    else {
        status = VibeMasterBusRenderSource(master, mix, &stamp, frames, list);
    }
    VibeFXChain *chain = atomic_load_explicit(&master->chain, memory_order_seq_cst);
    if (chain) {
        OSStatus fxStatus = VibeFXChainRender(chain, &stamp, frames, list);
        if (fxStatus != noErr) {
            // A failed effect leaves nothing usable: the slice is silence,
            // and the status reaches the output unit, which counts a dropout.
            VibeMasterBusZero(list, 0, frames);
            status = fxStatus;
        }
    }
    VibeLevelMeter *meter = atomic_load_explicit(&master->meter, memory_order_seq_cst);
    if (meter) {
        float *feed[2] = { list->mBuffers[0].mData, list->mBuffers[channels - 1].mData };
        VibeLevelMeterRender(meter, feed, channels, frames, &stamp);
    }
    VibeMasterBusApplyVolume(master, list, channels, frames);
    atomic_store_explicit(&master->frames, rendered + frames, memory_order_release);
    atomic_store_explicit(&master->pendingFrames, 0, memory_order_release);
    return status;
}

// The pipeline over `data`'s first buffers — the output's channels — in
// slices of at most kVibeMasterBusMaxFrames, whatever count the output unit
// hands it; any further buffers stay silent.
OSStatus VibeMasterBusRender(void *context, const AudioTimeStamp *hostStamp, UInt32 frames,
                                    AudioBufferList *data) CA_REALTIME_API {
    VibeMasterBus *master = context;
    int32_t outside = 0;
    if (!atomic_compare_exchange_strong_explicit(&master->inRender, &outside, 1, memory_order_seq_cst, memory_order_seq_cst)) {
        // A render is inside: this one is silence, and the door stays that
        // render's to release.
        atomic_fetch_add_explicit(&master->refusedRenders, 1, memory_order_relaxed);
        if (data) {
            VibeMasterBusZero(data, 0, frames);
        }
        return noErr;
    }
    OSStatus status = noErr;
    uint32_t channels = VibeMasterBusChannels(master);
    BOOL usable = atomic_load_explicit(&master->gate, memory_order_seq_cst) && data && frames > 0
            && channels > 0 && data->mNumberBuffers >= channels;
    for (UInt32 c = 0; usable && c < channels; c++) {
        usable = data->mBuffers[c].mData != NULL;
    }
    if (!usable) {
        if (data) {
            VibeMasterBusZero(data, 0, frames);
        }
    }
    else {
        for (UInt32 offset = 0; offset < frames; ) {
            UInt32 count = frames - offset < kVibeMasterBusMaxFrames ? frames - offset : kVibeMasterBusMaxFrames;
            OSStatus sliceStatus = VibeMasterBusRenderSlice(master, hostStamp, offset, count, data);
            if (sliceStatus != noErr) {
                status = sliceStatus;
            }
            offset += count;
        }
        for (UInt32 b = channels; b < data->mNumberBuffers; b++) {
            if (data->mBuffers[b].mData) {
                memset(data->mBuffers[b].mData, 0, frames * sizeof(float));
            }
        }
    }
    atomic_store_explicit(&master->inRender, 0, memory_order_release);
    return status;
}
VIBE_REALTIME_END

@implementation AudioPlayer (Pipeline)

#pragma mark - The output unit

- (void)createOutputOnQueue {
#if DEBUG
    // --no-audio-hw: no output unit; the pump stands in for the IO thread, at
    // real-time pace or frame-driven by a test. Even muted, hardware IO counts
    // as playing, which lets macOS pull auto-switching AirPods mid-test.
    // --silent: the device is driven, and the buffers are zeroed after the
    // meter.
    VibeManualRenderPump *pump = _manualPump;
    BOOL noAudioHW = pump != nil || [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    atomic_store_explicit(&_masterBus->silent, [NSProcessInfo.processInfo.arguments containsObject:@"--silent"] ? 1 : 0,
                          memory_order_relaxed);
    if (noAudioHW) {
        AVAudioFormat *format = pump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
        if (!pump) {
            pump = [[VibeManualRenderPump alloc] initWithFormat:format automatic:YES];
            _manualPump = pump;
        }
        // The pump is attached before the format lands: the format's FX
        // reconcile schedules its ramps through the pump, which needs its
        // queue by then. The gate is closed, so the paced pump renders
        // silence until a start.
        VibeMasterBus *master = _masterBus; // the blocks capture the pointer, never self
        [self attachPumpOnQueue:pump render:^OSStatus(AVAudioPCMBuffer *chunk, AVAudioFrameCount count) {
            chunk.frameLength = count;
            return VibeMasterBusRender(master, NULL, count, chunk.mutableAudioBufferList);
        } running:^BOOL{
            return atomic_load_explicit(&master->gate, memory_order_relaxed) != 0;
        }];
        [self setMasterBusFormatOnQueue:format];
        LogInfo(@"AudioPlayer: --no-audio-hw, no output device");
        return;
    }
#endif
    [self prepareOutputOnQueue];
}

- (void)attachOutputUnitOnQueue:(AudioOutputUnit *)unit {
    _outputUnit = unit;
    __weak AudioPlayer *weakSelf = self;
    dispatch_queue_t queue = _queue;
    unit.failureHandler = ^(NSError *error, uint64_t runGeneration, BOOL bindRefused) {
        dispatch_async(queue, ^{
            [weakSelf outputUnitFailedOnQueue:error runGeneration:runGeneration bindRefused:bindRefused];
        });
    };
}

// Moot when a later start or stop, or another unit, owns the output. A system
// stop (iOS, no error) only stops the output: the session's verdict decides
// the transport. A refusal also parks the current voice Paused and tells the
// owning play.
- (void)outputUnitFailedOnQueue:(NSError *)error runGeneration:(uint64_t)runGeneration bindRefused:(BOOL)bindRefused {
    if (_terminating || !_outputUnit || runGeneration != _outputUnit.runGeneration) {
        return;
    }
#if TARGET_OS_OSX
    if (error && bindRefused) {
        // Before the stop, whose liveness edge republishes the bit-perfect
        // report: it must not name the refused device. The next default or
        // selection binds again rather than reading a no-op.
        [_outputUnit forgetDevice];
    }
#endif
    [self stopOutputOnQueue];
    if (!error) {
        LogInfo(@"AudioPlayer: output stopped by the system while %@; the session's verdict decides the transport",
                _state == VibePlayerStatePlaying && _voice ? @"playing" : @"not playing");
        // TRAP: never paused here. The stop can land a millisecond before its
        // interruption's Began, whose was-playing the Ended resume depends on.
        // A stop no verdict follows (iOS stops the unit seconds before it
        // delivers a media-services reset) would leave Playing published
        // over a dead output, so the pause is what is left once the verdicts
        // have had their time.
        __weak AudioPlayer *weakSelf = self;
        [self scheduleAfterSeconds:kSystemStopVerdictSeconds block:^{
            AudioPlayer *strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_terminating || strongSelf->_state != VibePlayerStatePlaying
                    || !strongSelf->_voice || [strongSelf renderingOnQueue]) {
                return;
            }
            LogWarn(@"AudioPlayer: no verdict followed the system's stop; pausing");
            [strongSelf pauseCurrentVoiceOnQueue];
        }];
        return;
    }
    if (_state == VibePlayerStatePlaying && _voice) {
        [self pauseCurrentVoiceOnQueue];
    }
    [self sendDelegateError:VibeAudioError(bindRefused ? VibeAudioErrorDeviceUnavailable : VibeAudioErrorEngineStartFailed,
                                           @"Could not start the audio output", error)
           forSubmittedPlay:_activeSubmittedPlayIdentifier];
}

- (NSDictionary<NSString *, NSNumber *> *)outputUnitCountersOnQueue {
    return @{@"dropouts": @(_outputUnit.dropouts), @"renderCycles": @(_outputUnit.renderCycles),
             @"renderMeanMicros": @(_outputUnit.renderMeanMicroseconds),
             @"renderMaxMicros": @(_outputUnit.renderMaxMicroseconds)};
}

#if DEBUG
- (void)attachPumpOnQueue:(VibeManualRenderPump *)pump render:(VibeManualRenderBlock)render running:(BOOL (^)(void))running {
    // The pump stands in for the IO thread: the frame-driven mode decodes
    // inline before each slice, and both modes drain after it.
    __weak AudioPlayer *weakSelf = self;
    pump.beforeRender = pump.automatic ? nil : ^{
        AudioPlayer *strongSelf = weakSelf;
        [strongSelf->_voiceBus fillInline];
    };
    pump.afterRender = ^{ [weakSelf drainVoiceBusOnQueue]; };
    [pump attachRender:render running:running queue:_queue];
}

- (void)debugHoldDecoder:(BOOL)hold {
    [self runSyncOnQueue:^{ [self->_voiceBus debugHoldDecoder:hold]; }];
}

- (void)debugHoldRenderInside:(BOOL)hold {
    atomic_store_explicit(&_masterBus->holdRenderInside, hold ? 1 : 0, memory_order_seq_cst);
}

- (NSUInteger)debugRendersHeld {
    return (NSUInteger)atomic_load_explicit(&_masterBus->rendersHeld, memory_order_seq_cst);
}

// An output unit's callback on the caller's thread: buffers of its own, the
// pipeline's channels, nothing of the player's queue-owned state read.
- (void)debugRenderOnCallerThread:(NSUInteger)frames {
    VibeMasterBus *master = _masterBus;
    UInt32 count = (UInt32)MIN(frames, (NSUInteger)kVibeMasterBusMaxFrames);
    uint32_t channels = VibeMasterBusChannels(master);
    float *storage = calloc((size_t)count * 2 + 1, sizeof(float));
    VibeMasterBusStereoList list = { channels, {{0}} };
    for (uint32_t c = 0; c < channels; c++) {
        list.mBuffers[c].mNumberChannels = 1;
        list.mBuffers[c].mDataByteSize = count * (UInt32)sizeof(float);
        list.mBuffers[c].mData = storage + (size_t)c * count;
    }
    VibeMasterBusRender(master, NULL, count, (AudioBufferList *)&list);
    free(storage);
}
#endif

// The pipeline's format changed: the master bus follows, the FX chain is
// re-hosted at it, and the meter, which analyzes at one rate for its life,
// is replaced. The bus is the source segment's to rebuild.
- (void)setMasterBusFormatOnQueue:(AVAudioFormat *)format {
    _masterFormat = format;
    atomic_store_explicit(&_masterBus->channels, format.channelCount < 2 ? 1 : 2, memory_order_relaxed);
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    atomic_store_explicit(&_masterBus->hostTicksPerFrame, 1e9 * timebase.denom / ((double)timebase.numer * format.sampleRate),
                          memory_order_relaxed);
    [self reconcileFXOnQueue];
    if (_levelMeter && _levelMeter.sampleRate != format.sampleRate) {
        [self dropLevelMeterOnQueue];
        [self applyLevelMeterOnQueue];
    }
}

- (AVAudioFormat *)masterBusFormatOnQueue {
    return _masterFormat;
}

- (BOOL)fxWantedOnQueue {
    return _fxEnabled && ![self bitPerfectOnQueue];
}

// The chain is in the render only while it is connected: the pointer is
// withdrawn before the segment is reset or re-hosted — the disconnect waits
// the render out — and published once the units are up, so a disconnected
// segment costs the render nothing, not even its stages' flags.
- (void)reconcileFXOnQueue {
    if (!_masterFormat) {
        return;
    }
    atomic_store_explicit(&_masterBus->chain, NULL, memory_order_seq_cst);
    [self.fx setConnected:[self fxWantedOnQueue] format:_masterFormat maximumFrameCount:kVibeMasterBusMaxFrames];
    if (self.fx.connected) {
        atomic_store_explicit(&_masterBus->chain, self.fx.chain, memory_order_release);
    }
}

- (void)clearFXIntent {
    // A cutoff or level written directly clears its stage's toggles with it.
    self.fx.lowKillCutoffHz = 0;
    self.fx.reverbSendLevel = 0;
    self.fx.delaySendLevel = 0;
    self.fx.shortDelaySendEnabled = NO;
}

- (BOOL)resumeOutputAfterEditOnQueue:(BOOL)wasPlaying reason:(NSString *)reason {
    if (wasPlaying) {
        NSError *startError = nil;
        if (![self startOutputOnQueue:&startError]) {
            [self pauseCurrentVoiceOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                    [NSString stringWithFormat:@"Could not restart playback (%@)", reason], startError)];
            return NO;
        }
        [self armSignalProbeOnQueue:reason];
    }
    else if (_state == VibePlayerStatePaused) {
        [self scheduleOutputIdleStopOnQueue];
    }
    return YES;
}

- (void)applyLevelMeterOnQueue {
    BOOL wanted = _levelsWanted || self.signalProbeWanted;
    if (wanted) {
        if (!_levelMeter && _levelPublisher && _masterFormat) {
            _levelMeter = [[AudioLevelMeter alloc] initWithFormat:_masterFormat publisher:_levelPublisher
                                            normalizationMode:_levelNormalizationMode];
        }
        if (!_levelMeter || _levelMeter.installed) {
            return;
        }
        [_levelMeter install];
        atomic_store_explicit(&_masterBus->meter, _levelMeter.meter, memory_order_seq_cst);
        if (_state == VibePlayerStatePlaying && _voice) {
            [self armSignalProbeOnQueue:@"meter installed during playback"];
        }
    }
    else if (_levelMeter.installed) {
        // The pointer goes first; a render already inside publishes once
        // more into the session this ends, which the publisher drops.
        atomic_store_explicit(&_masterBus->meter, NULL, memory_order_seq_cst);
        [_levelMeter remove];
    }
}

- (void)dropLevelMeterOnQueue {
    AudioLevelMeter *meter = _levelMeter;
    if (!meter) {
        return;
    }
    atomic_store_explicit(&_masterBus->meter, NULL, memory_order_seq_cst);
    [meter remove];
    _levelMeter = nil;
    // The render may still be using the meter's storage.
    [self afterRenderLeavesOnQueue:^{ (void)meter; }];
}

// Called after the withdrawal is published, so a render seen outside is
// outside for good. TRAP: NO means a render is still inside; the caller must
// not free or reset anything it could be inside — the timeout is never
// permission. Teardowns go through afterRenderLeavesOnQueue:.
- (BOOL)waitForRenderToLeaveOnQueue {
    VibeMasterBus *master = _masterBus;
    uint64_t frames = atomic_load_explicit(&master->frames, memory_order_relaxed);
    // One bound per stuck render: still inside, with no slice finished since
    // the last timeout, it is the same render, and this teardown parks at once.
    if (_renderStuck && frames == _renderStuckFrames && VibeMasterBusRenderInside(master)) {
        return NO;
    }
    for (int spin = 0; spin < kRenderLeaveSpinLimit; spin++) {
        if (!VibeMasterBusRenderInside(master)) {
            _renderStuck = NO;
            [self runRenderLeaveWorkOnQueue];
            return YES;
        }
        usleep(kRenderLeaveSpinMicroseconds);
    }
    _renderStuck = YES;
    _renderStuckFrames = frames;
    LogError(@"AudioPlayer: a render did not leave the pipeline within %d ms; its teardowns wait for it",
             (int)(kRenderLeaveSpinLimit * kRenderLeaveSpinMicroseconds / 1000));
    return NO;
}

- (void)afterRenderLeavesOnQueue:(dispatch_block_t)work {
    if ([self waitForRenderToLeaveOnQueue]) {
        work();
        return;
    }
    [_renderLeaveWork addObject:[work copy]];
}

// The parked teardowns, in order; the caller has just seen the render
// outside the pipeline.
- (void)runRenderLeaveWorkOnQueue {
    if (_renderLeaveWork.count == 0) {
        return;
    }
    NSArray<dispatch_block_t> *work = [_renderLeaveWork copy];
    [_renderLeaveWork removeAllObjects];
    for (dispatch_block_t block in work) {
        block();
    }
}

// The bus leaves the render and dies with every voice; the caller decided
// nothing was audible.
- (void)dropVoiceBusOnQueue {
    AudioVoiceBus *old = _voiceBus;
    if (!old) {
        return;
    }
    atomic_store_explicit(&_masterBus->mix, NULL, memory_order_seq_cst);
    // TRAP: the new voice takes the same AudioFileHandle, and the old bus's
    // decoder may be inside a read of it (its queued turns retain the bus).
    // Its files are withheld from the new bus until it leaves them
    // (retiredDecoderLeftOnQueue:), so two decoders never move one cursor.
    // Never joined: a read on a stalled mount would hold the player queue for
    // the whole stall.
    NSSet<AudioFileHandle *> *files = old.filesInUse;
    for (AudioFileHandle *file in files) {
        [_retiredDecoderFiles addObject:file];
    }
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = nil;
    os_unfair_lock_unlock(&_stateLock);
    __weak AudioPlayer *weakSelf = self;
    [old stopReadingThen:^{ [weakSelf retiredDecoderLeftOnQueue:files]; }];
    [_retiringVoices removeAllObjects];
    [self unpublishVoiceOnQueue];
    // The slots' rings are freed with the bus, which a render may still be inside.
    [self afterRenderLeavesOnQueue:^{ (void)old; }];
}

// A retired bus's decoder has left its files: the current bus may read the
// ones no other retired decoder is still inside, and a successor refused
// while its file was withheld may queue now.
- (void)retiredDecoderLeftOnQueue:(NSSet<AudioFileHandle *> *)files {
    for (AudioFileHandle *file in files) {
        [_retiredDecoderFiles removeObject:file];
        if ([_retiredDecoderFiles countForObject:file] == 0) {
            [_voiceBus allowReadsOfFile:file];
        }
    }
    [self maybeArmSuccessorOnQueue];
}

#if !TARGET_OS_OSX
// The iOS media-services reset: every audio object is dead and must not be
// messaged. The unit is told so, and released: its end only disposes it, as
// the reset contract asks. The park and pending open go too, since their
// handles would be dead. createOutputOnQueue rebuilds.
- (void)dropOutputBoundStateOnQueue {
    if (_drainTimer) {
        dispatch_source_cancel(_drainTimer);
        _drainTimer = nil;
    }
    atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
    atomic_store_explicit(&_masterBus->chain, NULL, memory_order_seq_cst);
    [self.fx markDead];
    [self dropVoiceBusOnQueue];
    [self dropLevelMeterOnQueue];
    [_outputUnit markDead];
    _outputUnit = nil;
    [self publishOutputIdleOnQueue:YES];
    [self refreshOutputAudioActiveOnQueue];
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    [_pendingRequest invalidate];
    [self clearSuccessorOnQueue];
}
#endif


- (BOOL)renderingOnQueue {
    return atomic_load_explicit(&_masterBus->gate, memory_order_relaxed) != 0
            && (![self drivesOutputDeviceOnQueue] || _outputUnit.running);
}

- (uint64_t)renderedFramesOnQueue {
    return atomic_load_explicit(&_masterBus->frames, memory_order_acquire)
            + atomic_load_explicit(&_masterBus->pendingFrames, memory_order_acquire);
}

- (AudioTimeStamp)outputRenderTimeOnQueue {
    AudioTimeStamp time = {0};
    if (_masterFormat) {
        time.mSampleTime = (Float64)[self renderedFramesOnQueue];
        time.mFlags = kAudioTimeStampSampleTimeValid;
    }
    return time;
}

- (BOOL)varispeedPresentOnQueue {
    return atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed) != NULL;
}

- (BOOL)varispeedEngagedOnQueue {
    VibeVarispeedHost *host = atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed);
    return host && atomic_load_explicit(&host->engaged, memory_order_relaxed) != 0;
}

- (uint64_t)varispeedRendersOnQueue {
    return atomic_load_explicit(&_masterBus->varispeedRenders, memory_order_relaxed);
}

- (uint64_t)renderRefusalsOnQueue {
    return atomic_load_explicit(&_masterBus->refusedRenders, memory_order_relaxed);
}

- (void)clearRenderRefusalsOnQueue {
    atomic_store_explicit(&_masterBus->refusedRenders, 0, memory_order_relaxed);
}

- (uint64_t)varispeedHistoryWritesOnQueue {
    return atomic_load_explicit(&_masterBus->varispeedHistoryWrites, memory_order_relaxed);
}

// The unit's declared latency while it is in the chain — the pitch off zero
// — and nothing at zero, where the render skips it.
- (NSTimeInterval)varispeedLatencyOnQueue {
    if (!atomic_load_explicit(&_masterBus->varispeedWanted, memory_order_relaxed)) {
        return 0;
    }
    VibeVarispeedHost *host = atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed);
    return VibeAudioUnitSeconds(host ? host->unit : NULL, kAudioUnitProperty_Latency);
}

- (NSUInteger)hostedUnitCountOnQueue {
    return ([self varispeedPresentOnQueue] ? 1 : 0) + self.fx.hostedUnitCount;
}

#pragma mark - The source segment

// The unit and its rings go together, after the render was seen outside them.
static void VibeVarispeedHostFree(VibeVarispeedHost *host) {
    if (!host) {
        return;
    }
    VibeDisposeAudioUnit(&host->unit);
    free(host->recent[0]);
    free(host->scratch[0]);
    free(host);
}

VibeMasterBus *VibeMasterBusCreate(void) {
    VibeMasterBus *master = calloc(1, sizeof(VibeMasterBus));
    // TRAP: a zero-filled volume is silence.
    atomic_init(&master->volume, 1.0f);
    master->volumeApplied = 1.0f;
    atomic_init(&master->volumeSnap, 1);
    return master;
}

void VibeMasterBusSetVolume(VibeMasterBus *master, float gain) {
    atomic_store_explicit(&master->volume, gain, memory_order_relaxed);
}

BOOL VibeMasterBusRenderInside(VibeMasterBus *master) {
    return atomic_load_explicit(&master->inRender, memory_order_seq_cst) != 0;
}

void VibeMasterBusFree(VibeMasterBus *master) {
    VibeVarispeedHostFree(atomic_exchange_explicit(&master->varispeed, NULL, memory_order_seq_cst));
    free(master);
}

// The hosting leaves the bus now, and is freed once the render was seen
// outside it.
- (void)disposeVarispeedOnQueue {
    if (!atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed)) {
        return;
    }
    atomic_store_explicit(&_masterBus->varispeedWanted, 0, memory_order_seq_cst);
    VibeVarispeedHost *host = atomic_exchange_explicit(&_masterBus->varispeed, NULL, memory_order_seq_cst);
    [self afterRenderLeavesOnQueue:^{ VibeVarispeedHostFree(host); }];
}

// Hosts the varispeed at `format` for the bus: the highest render quality
// the unit offers, read back, and the rings the engage and disengage need,
// sized from its declared latency at that rate. NO with nothing hosted.
- (BOOL)hostVarispeedOnQueueWithFormat:(AVAudioFormat *)format {
    VibeVarispeedHost *host = calloc(1, sizeof(VibeVarispeedHost));
    if (!host) {
        return NO;
    }
    host->master = _masterBus;
    AURenderCallbackStruct input = { .inputProc = VibeMasterBusVarispeedInput, .inputProcRefCon = host };
    if (!VibeHostAudioUnit(&host->unit, kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed, format.streamDescription,
                           kVibeMasterBusMaxFrames, input, ^(AudioUnit instance) {
        UInt32 quality = kRenderQuality_Max;
        AudioUnitSetProperty(instance, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &quality, sizeof(quality));
    })) {
        free(host);
        return NO;
    }
    UInt32 quality = 0, size = sizeof(quality);
    if (AudioUnitGetProperty(host->unit, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &quality, &size) != noErr
            || quality != kRenderQuality_Max) {
        LogWarn(@"AudioPlayer: the varispeed renders at quality %u, not %u", (unsigned)quality, (unsigned)kRenderQuality_Max);
    }
    uint32_t latency = (uint32_t)MAX(1, llround(VibeAudioUnitSeconds(host->unit, kAudioUnitProperty_Latency) * format.sampleRate));
    // Twice the latency of history, the latency pulled ahead, and the
    // priming's outputs at any ratio the fader can reach: eight latencies,
    // rounded up to a power of two so the ring indexes by mask.
    uint32_t capacity = 256;
    while (capacity < 8 * latency) {
        capacity <<= 1;
    }
    host->recent[0] = calloc((size_t)capacity * 2, sizeof(float));
    host->scratch[0] = calloc((size_t)capacity * 2, sizeof(float));
    if (!host->recent[0] || !host->scratch[0]) {
        VibeVarispeedHostFree(host);
        return NO;
    }
    // TRAP: vDSP_vclr, not memset: clang drops a memset(0) after calloc (AudioVoiceBus's pre-touch).
    vDSP_vclr(host->recent[0], 1, (vDSP_Length)capacity * 2);
    vDSP_vclr(host->scratch[0], 1, (vDSP_Length)capacity * 2);
    host->recent[1] = host->recent[0] + capacity;
    host->scratch[1] = host->scratch[0] + capacity;
    host->recentMask = capacity - 1;
    host->latency = latency;
    host->quality = quality;
    atomic_store_explicit(&_masterBus->varispeed, host, memory_order_release);
    return YES;
}

- (BOOL)ensureSourceSegmentOnQueueRebuilt:(BOOL *)rebuilt {
    if (rebuilt) {
        *rebuilt = NO;
    }
    AVAudioFormat *busFormat = _masterFormat;
    if (!busFormat) {
        return NO;
    }
    // The bus always runs at the output's format, so a mode toggle or an
    // output rate change rebuilds it; the varispeed exists only for ordinary
    // playback on macOS, where pitch can leave zero.
#if TARGET_OS_OSX
    BOOL wantVarispeed = ![self bitPerfectOnQueue];
#else
    BOOL wantVarispeed = NO;
#endif
    if (_voiceBus && VibePCMFormatsMatch(_voiceBus.format, busFormat) && [self varispeedPresentOnQueue] == wantVarispeed) {
        return YES;
    }
    // Every voice dies with the old segment; the callers made sure none was
    // audible. The bus pointer is written under the lock the position getter
    // reads it under.
    [self stopOutputOnQueue];
    [self dropVoiceBusOnQueue];
    [self disposeVarispeedOnQueue];
#if DEBUG
    BOOL inlineDecoding = _manualPump != nil && ![(VibeManualRenderPump *)_manualPump automatic];
#else
    BOOL inlineDecoding = NO;
#endif
    AudioVoiceBus *bus = [[AudioVoiceBus alloc] initWithFormat:busFormat queue:_queue inlineDecoding:inlineDecoding];
    if (!bus) {
        LogError(@"AudioPlayer: no voice bus for %@", busFormat);
        return NO;
    }
    __weak AudioPlayer *weakSelf = self;
    bus.needsDrain = ^{ [weakSelf drainVoiceBusOnQueue]; };
    for (AudioFileHandle *file in _retiredDecoderFiles) {
        [bus withholdReadsOfFile:file];
    }
    if (wantVarispeed && ![self hostVarispeedOnQueueWithFormat:busFormat]) {
        return NO;
    }
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = bus;
    _busSampleRate = busFormat.sampleRate;
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    atomic_store_explicit(&_masterBus->mix, bus.mix, memory_order_release);
    [self applyPitchOnQueue:pitch];
    if (rebuilt) {
        *rebuilt = YES;
    }
    return YES;
}

// A Loading track's open starts itself; a Stopped one is not resurrected.
- (BOOL)reconcileSourceSegmentOnQueue {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(0, NO);
    AudioFileHandle *file = _file;
    BOOL restore = _state != VibePlayerStateLoading && file && [self getPlaybackIntent:&intent forTrack:nil];
    BOOL rebuilt = NO;
    if (![self ensureSourceSegmentOnQueueRebuilt:&rebuilt]) {
        return NO;
    }
    if (!rebuilt || !restore) {
        return YES;
    }
    [self revoiceOnQueueAtPosition:intent.position];
    return YES;
}

- (BOOL)followOutputFormatOnQueue:(AVAudioFormat *)format {
    if (!format || (_masterFormat && VibePCMFormatsMatch(_masterFormat, format))) {
        return YES;
    }
    BOOL wasPlaying = _state == VibePlayerStatePlaying && _voice != 0;
    [self stopOutputOnQueue];
    BOOL followed = NO;
#if DEBUG
    VibeManualRenderPump *pump = _manualPump;
    if (pump) {
        followed = [pump adoptFormat:format];
        if (followed) {
            [self setMasterBusFormatOnQueue:format];
        }
    }
    else
#endif
    {
        followed = [self adoptOutputFormatOnQueue:format];
    }
    if (!followed) {
        return NO;
    }
    if (![self reconcileSourceSegmentOnQueue]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                @"Could not restore the track at the output's new format", nil)];
        return NO;
    }
    if (![self resumeOutputAfterEditOnQueue:wasPlaying reason:@"output format change"]) {
        return NO;
    }
    [self maybeArmSuccessorOnQueue];
    LogInfo(@"AudioPlayer: the pipeline follows the output to %.0f Hz", format.sampleRate);
    return YES;
}

// The one mapping from the published pitch to the varispeed: the ratio, and
// whether the unit is wanted in the chain at all. At zero it is not — the
// render plays the bus straight, with no unit rendered and no delay — because
// even a ratio of 1.0 is not a pass-through (measured: 0.04 on noise). The
// render engages and disengages it at its next slice.
- (void)applyPitchOnQueue:(float)pitch {
    VibeVarispeedHost *host = atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed);
    if (!host) {
        return;
    }
    float rate = 1.0f + pitch / 100.0f;
    AudioUnitSetParameter(host->unit, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, rate, 0);
    atomic_store_explicit(&_masterBus->varispeedRateMilli, (int32_t)lroundf(rate * 1000.0f), memory_order_relaxed);
    atomic_store_explicit(&_masterBus->varispeedWanted, pitch != 0, memory_order_seq_cst);
}

#pragma mark - Starting and stopping

- (BOOL)startOutputOnQueue:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    if (_terminating) {
        return NO;
    }
    _outputIdleStopGeneration++; // playback is starting: cancel any pending idle stop
    // Before the unit can run, and kept by a failed start: only the idle
    // stop its caller re-arms answers idle again.
    [self publishOutputIdleOnQueue:NO];
    if (![self renderingOnQueue]) {
        // TRAP: only the manual pump may start without an output unit;
        // otherwise Playing and didStartPlaying: publish with no callback to
        // advance the voice, and the shell gets neither audio nor an error.
        atomic_store_explicit(&_masterBus->volumeSnap, 1, memory_order_release);
        atomic_store_explicit(&_masterBus->gate, 1, memory_order_seq_cst);
        NSError *error = nil;
        uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL started = ![self drivesOutputDeviceOnQueue] || [self startOutputUnitOnQueueWithError:&error];
        NSTimeInterval seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt) / NSEC_PER_SEC;
        BOOL slow = seconds > kSlowOutputStartLogThresholdSeconds;
        LogTiming(slow, @"AudioPlayer: %@output start %.3fs on the player queue",
                  slow ? @"slow " : @"", seconds);
        if (!started) {
            atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
            if (outError) {
                *outError = error;
            }
            return NO;
        }
    }
    [self applyLevelMeterOnQueue];
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
    [self noteOutputEdgeOnQueue];
    return YES;
}

- (void)stopOutputOnQueue {
    [_outputUnit stop];
    atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
    [self waitForRenderToLeaveOnQueue]; // the join a stop offers its callers; a stuck render's teardowns defer themselves
    for (NSNumber *voice in _retiringVoices) {
        [_voiceBus killVoice:voice.unsignedLongLongValue];
    }
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
    [self noteOutputEdgeOnQueue];
}

- (void)scheduleOutputIdleStopOnQueue {
    if (_terminating) {
        return;
    }
    [self armOutputIdleStopOnQueueAfter:kOutputIdleStopDelaySeconds generation:++_outputIdleStopGeneration waited:0];
}

// `waited` is how long the stop has already held for a tail past the delay.
- (void)armOutputIdleStopOnQueueAfter:(NSTimeInterval)seconds generation:(uint64_t)generation waited:(NSTimeInterval)waited {
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:seconds block:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_outputIdleStopGeneration) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_stateLock);
        VibePlayerState state = strongSelf->_state;
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        // Only a still-idle player stops the output. Loading counts as busy,
        // because the in-flight open's settlement wants a warm output. A
        // paused voice keeps its state; resume restarts the output.
        if (state != VibePlayerStateStopped && state != VibePlayerStatePaused) {
            return;
        }
        // A ringing send tail keeps the output, bounded by the longest
        // declared tail so a send held through the pause cannot hold the
        // device.
        AudioFX *fx = strongSelf.fx;
        if (fx.sendsActive && waited < fx.longestTailSeconds) {
            if (waited == 0) {
                LogInfo(@"AudioPlayer: the idle stop waits for an FX tail, at most %.1f s", fx.longestTailSeconds);
            }
            [strongSelf armOutputIdleStopOnQueueAfter:kOutputIdleStopTailIntervalSeconds generation:generation
                                               waited:waited + kOutputIdleStopTailIntervalSeconds];
            return;
        }
        [strongSelf stopOutputOnQueue];
        // On iOS the release returns with the unit's stop landed, which is
        // what lets the shell release the session on the edge below.
        [strongSelf releaseIdleOutputUnitOnQueue];
        [strongSelf publishOutputIdleOnQueue:YES];
    }];
}

#pragma mark - The drain

- (void)drainVoiceBusOnQueue {
    if (_renderLeaveWork.count && !VibeMasterBusRenderInside(_masterBus)) {
        [self runRenderLeaveWorkOnQueue]; // a render that left late is followed within a drain interval
    }
    AudioVoiceBus *bus = _voiceBus;
    if (!bus) {
        return;
    }
    [self republishEstimatedWindowOnQueue];
    [bus drainWithOutputRunning:[self renderingOnQueue] handler:^(VibeVoiceID voice, VibeVoiceEvent event) {
        [self handleVoiceEventOnQueue:event voice:voice];
    }];
    [self updateBufferingOnQueue];
    [self maybeCrossfadeIntoParkOnQueue];
    [self noteDrainOnQueue];
    [self updateDrainTimerOnQueue];
}

- (NSDictionary<NSString *, id> *)pipelineRenderSnapshotOnQueue {
    VibeMasterBus *master = _masterBus;
    VibeVarispeedHost *host = atomic_load_explicit(&master->varispeed, memory_order_relaxed);
    NSDictionary *varispeedStage = @{
        @"stage": @"varispeed", @"present": @(host != NULL),
        @"wanted": @(atomic_load_explicit(&master->varispeedWanted, memory_order_relaxed) != 0),
        @"engaged": @(host && atomic_load_explicit(&host->engaged, memory_order_relaxed) != 0),
        @"pitch": @(self.pitch),
        @"rate": @(atomic_load_explicit(&master->varispeedRateMilli, memory_order_relaxed) / 1000.0),
        @"latencySeconds": @(VibeAudioUnitSeconds(host ? host->unit : NULL, kAudioUnitProperty_Latency)),
        @"latencyFrames": @(host ? host->latency : 0),
        @"quality": @(host ? host->quality : 0),
        @"renders": @(atomic_load_explicit(&master->varispeedRenders, memory_order_relaxed)),
    };

    return @{@"varispeed": varispeedStage,
             @"fxInRender": @(atomic_load_explicit(&master->chain, memory_order_relaxed) != NULL),
             @"meterInRender": @(atomic_load_explicit(&master->meter, memory_order_relaxed) != NULL),
             @"silent": @(atomic_load_explicit(&master->silent, memory_order_relaxed) != 0),
             @"framesRendered": @(atomic_load_explicit(&master->frames, memory_order_relaxed))};
}

- (void)updateDrainTimerOnQueue {
#if DEBUG
    if (_manualPump) {
        return; // the pump drains after every slice
    }
#endif
    BOOL wanted = [self renderingOnQueue] && _voiceBus.occupiedSlotCount > 0;
    if (!wanted) {
        if (_drainTimer) {
            dispatch_source_cancel(_drainTimer);
            _drainTimer = nil;
        }
        return;
    }
    uint64_t interval = _retiringVoices.count || _renderLeaveWork.count || _voiceBus.promptDrainDue
            ? kDrainIntervalNanos : kDrainSteadyIntervalNanos;
    if (_drainTimer && interval == _drainTimerInterval) {
        return;
    }
    if (!_drainTimer) {
        _drainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        __weak AudioPlayer *weakSelf = self;
        dispatch_source_set_event_handler(_drainTimer, ^{ [weakSelf drainVoiceBusOnQueue]; });
        dispatch_resume(_drainTimer);
    }
    _drainTimerInterval = interval;
    dispatch_source_set_timer(_drainTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 4);
}

@end
