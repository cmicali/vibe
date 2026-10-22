//
//  AudioVoiceBusRender.m
//  Vibe
//
//  The audio thread's side of the bus: VibeVoiceBusRender and its mix
//  helpers. Plain C over the mix (AudioVoiceBusInternal.h).
//

#import "AudioVoiceBusInternal.h"
#import "VibeMacros.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - The audio thread

// The stamps are a seqlock: the version goes odd, the words are written,
// the version goes even, with fences either side of the words so a reader
// that saw the same even version before and after its copy has a coherent
// one. Every word is an atomic, so the copy is race-free, not merely
// detected as torn.
static inline void VibeStampWrite(VibeVoiceSlot *slot, VibeVoiceStamp *field, const AudioTimeStamp *base,
                                  uint64_t frameOffset, double ticksPerFrame) CA_REALTIME_API {
    Float64 sampleTime = base->mSampleTime;
    UInt64 hostTime = base->mHostTime;
    uint32_t flags = base->mFlags;
    if (flags & kAudioTimeStampSampleTimeValid) {
        sampleTime += (Float64)frameOffset;
    }
    if (flags & kAudioTimeStampHostTimeValid) {
        hostTime += (UInt64)((double)frameOffset * ticksPerFrame);
    }
    uint64_t bits;
    memcpy(&bits, &sampleTime, sizeof(bits));
    atomic_fetch_add_explicit(&slot->stampVersion, 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&field->sampleTimeBits, bits, memory_order_relaxed);
    atomic_store_explicit(&field->hostTime, hostTime, memory_order_relaxed);
    atomic_store_explicit(&field->flags, flags, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_fetch_add_explicit(&slot->stampVersion, 1, memory_order_relaxed);
}

static void VibeVoiceDie(VibeVoiceSlot *slot, int32_t reason, uint64_t renderSequence) CA_REALTIME_API {
    int32_t expected = VibeVoiceStateLive;
    int32_t none = VibeVoiceEndNone;
    atomic_compare_exchange_strong_explicit(&slot->endedReason, &none, reason,
                                            memory_order_relaxed, memory_order_relaxed);
    atomic_store_explicit(&slot->diedAtRender, renderSequence, memory_order_relaxed);
    atomic_compare_exchange_strong_explicit(&slot->state, &expected, VibeVoiceStateDead,
                                            memory_order_release, memory_order_relaxed);
}

// The calls the compiler cannot check: vDSP and vForce, which neither allocate
// nor block but carry no attribute, and the debug sleep of a held render.
VIBE_REALTIME_UNCHECKED_BEGIN
#if DEBUG
static inline void VibeVoiceBusHoldWait(void) CA_REALTIME_API {
    usleep(200);
}
#endif
static inline void VibeVoiceMixAdd(const float *ring, float *out, uint32_t frames) CA_REALTIME_API {
    vDSP_vadd(ring, 1, out, 1, out, 1, frames);
}

static inline void VibeVoiceMixAtGain(const float *ring, float gain, float *out, uint32_t frames) CA_REALTIME_API {
    vDSP_vsma(ring, 1, &gain, out, 1, out, 1, frames);
}

static inline void VibeVoiceMixAtGains(const float *ring, const float *gains, float *out, uint32_t frames) CA_REALTIME_API {
    vDSP_vma(ring, 1, gains, 1, out, 1, out, 1, frames);
}

static inline void VibeVoiceLinearRamp(float first, float step, float *out, uint32_t count) CA_REALTIME_API {
    vDSP_vramp(&first, &step, out, 1, count);
}

// The equal-power root, floored at zero so a rounding below it is not a NaN.
static inline void VibeVoiceSquareRoot(float *samples, uint32_t count) CA_REALTIME_API {
    float zero = 0;
    vDSP_vthr(samples, 1, &zero, samples, 1, count);
    int n = (int)count;
    vvsqrtf(samples, samples, &n);
}

static inline void VibeVoiceFill(float value, float *out, uint32_t count) CA_REALTIME_API {
    vDSP_vfill(&value, out, 1, count);
}
VIBE_REALTIME_END

// Everything the audio thread does; the checked region makes a blocking call a
// build error.
VIBE_REALTIME_CHECKED_BEGIN

// VibeFadeGainAtFrame for `count` consecutive frames from `firstFrame`, in
// ramp form: one vDSP ramp over the linear term (the gain, or the power under
// an equal-power root), the root through vForce, and `to` for every frame at
// or past the end. The same values to a rounding; the bus tests compare a
// rendered fade against the per-frame function at 1e-6.
static inline void VibeVoiceGainRamp(VibeFadeCurve curve, float from, float to, uint32_t firstFrame, uint32_t frames,
                                     uint32_t count, float *gains) CA_REALTIME_API {
    uint32_t ramped = frames > firstFrame ? frames - firstFrame : 0;
    if (ramped > count) {
        ramped = count;
    }
    if (ramped) {
        BOOL equalPower = curve == VibeFadeCurveEqualPower;
        float start = equalPower ? from * from : from;
        float step = ((equalPower ? to * to : to) - start) / (float)frames;
        VibeVoiceLinearRamp(start + step * (float)firstFrame, step, gains, ramped);
        if (equalPower) {
            VibeVoiceSquareRoot(gains, ramped);
        }
    }
    if (count > ramped) {
        VibeVoiceFill(to, gains + ramped, count - ramped);
    }
}

OSStatus VibeVoiceBusRender(VibeVoiceMix *mix, BOOL *isSilence, const AudioTimeStamp *timestamp,
                            AVAudioFrameCount frameCount, AudioBufferList *output) CA_REALTIME_API {
    atomic_store_explicit(&mix->inRender, 1, memory_order_seq_cst);
#if DEBUG
    if (atomic_load_explicit(&mix->holdRender, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&mix->rendersHeld, 1, memory_order_seq_cst);
        while (atomic_load_explicit(&mix->holdRender, memory_order_relaxed)) {
            VibeVoiceBusHoldWait();
        }
        atomic_fetch_sub_explicit(&mix->rendersHeld, 1, memory_order_seq_cst);
    }
#endif
    uint64_t renderSequence = atomic_load_explicit(&mix->renderSequence, memory_order_relaxed);
    uint32_t channels = output->mNumberBuffers < mix->channels ? output->mNumberBuffers : mix->channels;
    for (uint32_t c = 0; c < output->mNumberBuffers; c++) {
        memset(output->mBuffers[c].mData, 0, output->mBuffers[c].mDataByteSize);
    }
    BOOL mixed = NO;
    for (uint32_t s = 0; s < kVoiceSlots; s++) {
        VibeVoiceSlot *slot = &mix->slots[s];
        if (atomic_load_explicit(&slot->state, memory_order_acquire) != VibeVoiceStateLive) {
            continue;
        }
        // Adopt a new ramp from the current gain. Adoption un-pauses, which is
        // how a resume, a seek's fade-in and a cancelled pause all work with
        // no resume action; zero frames land at once.
        uint64_t word = atomic_load_explicit(&slot->ramp, memory_order_acquire);
        uint32_t sequence = (uint32_t)(word >> 44) & 0xFFFFF;
        if (sequence != 0 && sequence != slot->rampSequence) {
            slot->rampSequence = sequence;
            slot->rampFrom = atomic_load_explicit(&slot->gain, memory_order_relaxed);
            slot->rampTo = (float)(word & 0xFFFF) / 65535.0f;
            slot->rampFrames = (uint32_t)((word >> 16) & 0xFFFFFF);
            slot->rampElapsed = 0;
            slot->rampCurve = (int32_t)((word >> 40) & 3);
            slot->rampAction = (int32_t)((word >> 42) & 3);
            atomic_store_explicit(&slot->paused, 0, memory_order_relaxed);
            if (slot->rampFrames == 0) {
                atomic_store_explicit(&slot->gain, slot->rampTo, memory_order_relaxed);
                if (slot->rampAction == VibeVoiceActionRetire) {
                    VibeVoiceDie(slot, VibeVoiceEndRetired, renderSequence);
                    continue;
                }
                if (slot->rampAction == VibeVoiceActionPause) {
                    atomic_store_explicit(&slot->paused, 1, memory_order_relaxed);
                    slot->consuming = 0;
                }
            }
        }
        if (atomic_load_explicit(&slot->paused, memory_order_relaxed)) {
            continue;
        }
        uint64_t written = atomic_load_explicit(&slot->written, memory_order_acquire);
        // Sequentially consistent, paired with the reopen's withdrawal of the
        // end: either this render sees the end withdrawn, or the reopen sees
        // this render in flight and waits for its verdict.
        uint64_t endOfStream = atomic_load_explicit(&slot->endOfStream, memory_order_seq_cst);
        uint64_t consumed = atomic_load_explicit(&slot->consumed, memory_order_relaxed);
        uint64_t available = written - consumed;
        uint32_t frames = available < frameCount ? (uint32_t)available : frameCount;
        BOOL ramping = slot->rampElapsed < slot->rampFrames;
        BOOL landsHere = NO;
        if (ramping && slot->rampAction != VibeVoiceActionNone) {
            // A pause or retire lands on an exact frame: nothing past it is mixed.
            uint32_t untilLanding = slot->rampFrames - slot->rampElapsed;
            if (untilLanding <= frames) {
                frames = untilLanding;
                landsHere = YES;
            }
        }
        if (frames > 0) {
            uint32_t readIndex = (uint32_t)(consumed & mix->mask);
            float gain = atomic_load_explicit(&slot->gain, memory_order_relaxed);
            // The ring read is at most two contiguous spans, each one vector
            // operation per channel; a fading voice's gains are one ramp per
            // span, shared by its channels.
            for (uint32_t done = 0; done < frames; ) {
                uint32_t index = (readIndex + done) & mix->mask;
                uint32_t span = frames - done;
                if (span > mix->capacity - index) {
                    span = mix->capacity - index;
                }
                if (span > kVibeVoiceBusMaxRenderFrames) {
                    span = kVibeVoiceBusMaxRenderFrames;
                }
                if (ramping) {
                    VibeVoiceGainRamp((VibeFadeCurve)slot->rampCurve, slot->rampFrom, slot->rampTo,
                                      slot->rampElapsed + done, slot->rampFrames, span, mix->gains);
                }
                for (uint32_t c = 0; c < channels; c++) {
                    const float *ring = mix->rings[s][c] + index;
                    float *out = (float *)output->mBuffers[c].mData + done;
                    if (ramping) {
                        VibeVoiceMixAtGains(ring, mix->gains, out, span);
                    }
                    else if (gain == 1.0f) {
                        VibeVoiceMixAdd(ring, out, span);
                    }
                    else {
                        VibeVoiceMixAtGain(ring, gain, out, span);
                    }
                }
                done += span;
            }
            if (!slot->consuming) {
                slot->consuming = 1;
                VibeStampWrite(slot, &slot->startStamp, timestamp, 0, mix->hostTicksPerFrame);
            }
            consumed += frames;
            atomic_store_explicit(&slot->consumed, consumed, memory_order_release);
            mixed = YES;
        }
        if (frames < frameCount && !landsHere && endOfStream == kUnset) {
            // Hold the position, zero-fill (already zero), count it.
            atomic_fetch_add_explicit(&slot->underrun, frameCount - frames, memory_order_relaxed);
        }
        if (ramping) {
            // Block frames, not consumed frames: a starved retiring voice
            // still dies on schedule, and a landing here is exact.
            uint32_t advance = landsHere ? frames : frameCount;
            slot->rampElapsed = slot->rampElapsed + advance >= slot->rampFrames
                    ? slot->rampFrames : slot->rampElapsed + advance;
            if (slot->rampElapsed >= slot->rampFrames) {
                atomic_store_explicit(&slot->gain, slot->rampTo, memory_order_relaxed);
                if (slot->rampAction == VibeVoiceActionRetire) {
                    VibeVoiceDie(slot, VibeVoiceEndRetired, renderSequence);
                    continue;
                }
                if (slot->rampAction == VibeVoiceActionPause) {
                    atomic_store_explicit(&slot->paused, 1, memory_order_relaxed);
                    slot->consuming = 0;
                }
            }
            else {
                atomic_store_explicit(&slot->gain,
                                      VibeFadeGainAtFrame((VibeFadeCurve)slot->rampCurve, slot->rampFrom, slot->rampTo,
                                                          slot->rampElapsed, slot->rampFrames),
                                      memory_order_relaxed);
            }
        }
        if (endOfStream != kUnset && consumed >= endOfStream) {
            VibeVoiceDie(slot, VibeVoiceEndOfStream, renderSequence);
        }
    }
    *isSilence = !mixed;
    atomic_store_explicit(&mix->renderSequence, renderSequence + 1, memory_order_release);
    atomic_store_explicit(&mix->inRender, 0, memory_order_release);
    return noErr;
}
VIBE_REALTIME_END
