//
//  AudioMasterBus.m
//  Vibe
//

#import "AudioMasterBusInternal.h"
#import <Accelerate/Accelerate.h>

// The calls the compiler cannot check: the volume's vDSP, which Accelerate
// attributes with nothing, and, in debug builds, the sleep of a test's render
// held inside the pipeline.
VIBE_REALTIME_UNCHECKED_BEGIN
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

// The varispeed's source, and the slice's without one: the bus the slice
// read, which is `context`.
static OSStatus VibeMasterBusSource(void *context, const AudioTimeStamp *stamp, UInt32 frames,
                                    AudioBufferList *into) CA_REALTIME_API {
    BOOL silence = NO;
    return VibeVoiceBusRender(context, &silence, stamp, frames, into);
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
    VibeStereoBufferList slice = VibeStereoBufferListSpan(data, VibeMasterBusChannels(master), offset, frames);
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
        // No bus is published only with the output stopped, around a segment
        // rebuild that replaces the varispeed too.
        VibeMasterBusZero(list, 0, frames);
    }
    else {
        // Read once: a re-host swaps the pointer, and this render finishes
        // inside the stage it read.
        VibeVarispeed *varispeed = atomic_load_explicit(&master->varispeed, memory_order_seq_cst);
        status = varispeed ? VibeVarispeedRender(varispeed, VibeMasterBusSource, mix, &stamp, frames, list)
                           : VibeMasterBusSource(mix, &stamp, frames, list);
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

#pragma mark - The queue's calls

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

void VibeMasterBusFree(VibeMasterBus *master) {
    VibeVarispeedFree(atomic_exchange_explicit(&master->varispeed, NULL, memory_order_seq_cst));
    free(master);
}
