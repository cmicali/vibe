//
//  AudioFX.m
//  Vibe
//

#import "AudioFX.h"
#import "AudioFXMath.h"
#import "FadeMath.h"
#import <AVFAudio/AVFAudio.h>
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#include <stdatomic.h>

// The low kill is two cascaded high-pass bands swept together, 24 dB/oct in
// total: a resonant one with a small DJ-filter bump, and a 2nd-order
// Butterworth. Its cutoffs are AudioFXMath.h's.
//
// The resonant band's bandwidth in octaves; narrower is peakier.
static const float kLowKillResonanceBandwidth = 0.7f;
// Bandwidth of the parked bands, which only shapes how the old response's
// residue dies after the swap: two octaves settles in ~60 ms without the
// ~250 ms ring the resonant bandwidth gives.
static const float kLowKillFlatBandwidth = 2.0f;
// Fine steps, so coefficient jumps never zipper; 80 ms in all still reads as
// an instant kill.
static const int kLowKillSweepSteps = 40;
static const uint64_t kLowKillSweepStepMicroseconds = 2000;
// How long a parked EQ keeps rendering for that residue before it is reset
// and skipped.
static const NSTimeInterval kLowKillSettleSeconds = 0.25;

// The reverb send's open gate level: the wet-dry balance, since the dry path
// runs at unity; below 0.5 keeps the verb under the dry signal.
static const float kReverbSendLevel = 0.3f;
// High-pass on the reverb return, not the send, so even the tail is low-cut.
static const float kReverbTailLowCutHz = 550.0f;
#if TARGET_OS_OSX
// MatrixReverb over the Cathedral preset. TRAP: AudioUnitParameters.h's
// ranges are stale: the real LargeSize range (kAudioUnitProperty_ParameterInfo)
// is 0.005-0.15, not "0.4->10.0 Secs", and an out-of-range value aborts the
// render thread (caulk CAVerboseAbort) on first play. With no decay knob, the
// size, mix and density below give the longest tail it has.
static const float kReverbLargeSize = 0.15f;     // the real max: the tail knob
static const float kReverbSmallLargeMix = 90.0f; // 0-100: mostly the large hall engine
static const float kReverbLargeDensity = 0.9f;   // lush, smooth tail
static const SInt32 kReverbCathedralPreset = 8;  // MatrixReverb's factory preset list, read at host
#endif

// The delay sends' taps, in beats of the effective, pitch-scaled tempo:
static const float kDelayTapBeats = 0.5f;       // R: 1/8 note, half a beat
static const float kShortDelayTapBeats = 0.25f; // T: 1/16 note, a quarter beat
static const float kDelaySendLevel = 0.3f;
// Per-hop echo decay (L->R is one hop); each lane's own feedback is this
// squared, per the topology comment.
static const float kDelayFeedbackPercent = 75.0f; // aggressive: a long trail of repeats
// High-pass on the delay return, which every repeat re-exits through;
// AUDelay's in-loop filter is lowpass-only.
static const float kDelayEchoLowCutHz = 450.0f;
// Ping-pong width: echoes alternate sides at half pan, not hard left and right.
static const float kDelayPingPongPan = 0.5f;

// A held send keeps swelling after its fast open, by this ratio over six
// seconds in ~0.5% steps; release still closes fast.
static const float kReverbSwellRatio = 1.8f; // 0.3 -> 0.54
static const float kDelaySwellRatio = 1.8f;  // 0.3 -> 0.54
static const int kSendSwellSteps = 120;
static const uint64_t kSendSwellStepMicroseconds = 50000; // 120 x 50ms = 6s

// A gate's gain slews full scale in 25 ms on the audio thread, smoothing the
// queue's stepped ramps.
static const double kGateSlewSeconds = 0.025;

// One complete ping-pong delay send and return, built once per tap length, so
// that the 1/8-note (R) and 1/16-note (T) echoes are the same machine at
// different clock divisions. Instead of a cross-fed feedback cycle, two
// acyclic lanes run at twice the tap period T, the left offset by T, and
// interleave into an exact alternating pattern. All delays are 100% wet, with
// per-hop decay f:
//
//   send -> half(T) -------------------> panLeft (-50%)   L: T
//           half -> left(2T,f^2) ------> panLeft          L: 3T, 5T ...
//   send -> right(2T,f^2) ------------> panRight(+50%, volume f)
//                                                         R: 2T, 4T ...
//   panLeft + panRight -> echoes -> lowCut -> out
//
// The pans and sums are arithmetic in VibeFXChainRender, and the two sends'
// identical low-cuts are one linear filter over their summed returns.
//
// The non-geometric decay is deliberate: `left`'s first wet tap emerges at
// unity and panLeft cannot compensate without dimming the T tap, so every odd
// hop from 3 lands f^2 hotter (1, f, 1, f^3, f^2, ...). The left-leaning surge
// reads as bounce, and is kept.

#pragma mark - The chain

// A stereo buffer list the render can build on its stack.
typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} VibeFXStereoList;

// One hosted unit and the scratch pair its input callback copies from.
typedef struct {
    AudioUnit _Nullable unit;
    float *source[2];
} VibeFXUnit;

// The units, in the order the render meets them; a stage owns a run of them.
typedef enum {
    VibeFXUnitEQ,
    VibeFXUnitReverb,
    VibeFXUnitReverbLowCut,
    VibeFXUnitDelayLowCut, // both delay sends' returns, summed first
    VibeFXUnitHalf0, VibeFXUnitLeft0, VibeFXUnitRight0,
    VibeFXUnitHalf1, VibeFXUnitLeft1, VibeFXUnitRight1,
    VibeFXUnitCount,
} VibeFXUnitIndex;

// A stage: the low kill, or a send-return with its gate. The queue writes
// the target and the generation and flips `active`; the audio thread slews
// `gain` toward the target and reads `active` before touching the stage.
typedef struct {
    _Atomic float target;      // the send gate's level; the low kill has no gate
    _Atomic int32_t active;    // 1 while the stage is in the render
    float gain;                // the audio thread's slewed gate
    uint64_t generation;       // the ramp in flight; a newer toggle preempts by bumping it
    double tailSeconds;        // how long the stage renders after its gate closed
    VibeFXUnitIndex firstUnit; // the units the stage owns, for its rest
    int unitCount;
    BOOL enabled;              // the send's intent, lock-guarded
    float level;               // the send's open level, and how far it swells while held
    float swellRatio;
} VibeFXStage;

typedef enum {
    VibeFXStageLowKill,
    VibeFXStageReverb,
    VibeFXStageDelay,      // the 1/8-note send
    VibeFXStageShortDelay, // the 1/16-note send
    VibeFXStageCount,
} VibeFXStageIndex;

// One hosting of the segment: the units and the scratch at one format, over
// the object's stages and render counter; freed only once the render was
// seen outside it.
struct VibeFXChain {
    _Atomic uint64_t *unitRenders; // the object's, for its life
    double sampleRate;
    float slewPerFrame;
    UInt32 maxFrames;
    double delayLowCutTail; // the shared return filter's tail, read once at host
    VibeFXStage *stages;    // the object's, for its life
    VibeFXUnit units[VibeFXUnitCount];
    // Scratch, stereo, maxFrames each: a gated send, a unit's output on its
    // way to the next, the half-tap lane, a lane in flight, the delay returns
    // summed before their one low-cut, and every return summed before it
    // rejoins the dry path.
    float *send[2];
    float *wet[2];
    float *halfTap[2];
    float *lane[2];
    float *echoes[2];
    float *returns[2];
    float *storage;
};

#pragma mark - The audio thread

// The calls the compiler cannot check: AudioUnitRender and vDSP, realtime-safe
// but carrying no attribute.
VIBE_REALTIME_UNCHECKED_BEGIN
static inline OSStatus VibeFXRenderUnit(VibeFXChain *chain, VibeFXUnit *unit, const AudioTimeStamp *timestamp,
                                        UInt32 frames, float *const out[2]) CA_REALTIME_API {
    VibeFXStereoList list = { 2, { { 1, frames * (UInt32)sizeof(float), out[0] }, { 1, frames * (UInt32)sizeof(float), out[1] } } };
    AudioUnitRenderActionFlags flags = 0;
    atomic_fetch_add_explicit(chain->unitRenders, 1, memory_order_relaxed);
    return AudioUnitRender(unit->unit, &flags, timestamp, 0, frames, (AudioBufferList *)&list);
}

static inline void VibeFXVectorAdd(const float *in, float *out, UInt32 frames) CA_REALTIME_API {
    vDSP_vadd(in, 1, out, 1, out, 1, frames); // out += in
}

static inline void VibeFXVectorScale(const float *in, float scalar, float *out, UInt32 frames) CA_REALTIME_API {
    vDSP_vsmul(in, 1, &scalar, out, 1, frames); // out = in × scalar
}

static inline void VibeFXVectorScaleAdd(const float *in, float scalar, float *out, UInt32 frames) CA_REALTIME_API {
    vDSP_vsma(in, 1, &scalar, out, 1, out, 1, frames); // out += in × scalar
}
VIBE_REALTIME_END

VIBE_REALTIME_CHECKED_BEGIN
static inline void VibeFXCopy(float *const to[2], float *const from[2], UInt32 frames) CA_REALTIME_API {
    memcpy(to[0], from[0], frames * sizeof(float));
    memcpy(to[1], from[1], frames * sizeof(float));
}

static inline void VibeFXAdd(float *const to[2], float *const from[2], UInt32 frames) CA_REALTIME_API {
    VibeFXVectorAdd(from[0], to[0], frames);
    VibeFXVectorAdd(from[1], to[1], frames);
}

// A balance law: the far side attenuates linearly with the pan, the near side
// keeps its gain. Adds into `out`, or replaces it.
static inline void VibeFXPanInto(float *const lane[2], float *const out[2], UInt32 frames, float pan, float volume,
                                 BOOL add) CA_REALTIME_API {
    float left = volume * (pan > 0 ? 1.0f - pan : 1.0f);
    float right = volume * (pan < 0 ? 1.0f + pan : 1.0f);
    if (add) {
        VibeFXVectorScaleAdd(lane[0], left, out[0], frames);
        VibeFXVectorScaleAdd(lane[1], right, out[1], frames);
    }
    else {
        VibeFXVectorScale(lane[0], left, out[0], frames);
        VibeFXVectorScale(lane[1], right, out[1], frames);
    }
}

// Slewed per frame, so a target written mid-block lands smoothly.
static inline void VibeFXGate(VibeFXStage *stage, float *const in[2], float *const out[2], UInt32 frames,
                              float slew) CA_REALTIME_API {
    float gain = stage->gain;
    float target = atomic_load_explicit(&stage->target, memory_order_relaxed);
    if (gain == target) {
        if (gain == 0) {
            memset(out[0], 0, frames * sizeof(float));
            memset(out[1], 0, frames * sizeof(float));
        }
        else {
            VibeFXVectorScale(in[0], gain, out[0], frames);
            VibeFXVectorScale(in[1], gain, out[1], frames);
        }
        return;
    }
    for (UInt32 f = 0; f < frames; f++) {
        if (gain < target) {
            gain = gain + slew > target ? target : gain + slew;
        }
        else if (gain > target) {
            gain = gain - slew < target ? target : gain - slew;
        }
        out[0][f] = in[0][f] * gain;
        out[1][f] = in[1][f] * gain;
    }
    stage->gain = gain;
}

OSStatus VibeFXChainRender(VibeFXChain *chain, const AudioTimeStamp *timestamp, UInt32 frames, AudioBufferList *io) CA_REALTIME_API {
    if (!chain || frames == 0 || frames > chain->maxFrames || io->mNumberBuffers < 2) {
        return noErr;
    }
    float *out[2] = { io->mBuffers[0].mData, io->mBuffers[1].mData };
    OSStatus status = noErr;
    // The low kill, in place: the EQ's input callback copies the output
    // buffers into its own before it writes them.
    // TRAP: every unit's status is read, and the first failure returns at
    // once: a failed return holds stale scratch, which would play as the
    // current audio.
    if (atomic_load_explicit(&chain->stages[VibeFXStageLowKill].active, memory_order_seq_cst)) {
        VibeFXUnit *eq = &chain->units[VibeFXUnitEQ];
        eq->source[0] = out[0];
        eq->source[1] = out[1];
        status = VibeFXRenderUnit(chain, eq, timestamp, frames, out);
        if (status != noErr) {
            return status;
        }
    }
    // Every send taps the same post-low-kill signal, so the returns rejoin the
    // dry path only after every send has read it.
    BOOL returns = NO;
    VibeFXStage *reverb = &chain->stages[VibeFXStageReverb];
    if (atomic_load_explicit(&reverb->active, memory_order_seq_cst)) {
        VibeFXGate(reverb, out, chain->send, frames, chain->slewPerFrame);
        if ((status = VibeFXRenderUnit(chain, &chain->units[VibeFXUnitReverb], timestamp, frames, chain->wet)) != noErr
                || (status = VibeFXRenderUnit(chain, &chain->units[VibeFXUnitReverbLowCut], timestamp, frames, chain->returns)) != noErr) {
            return status;
        }
        returns = YES;
    }
    BOOL echoes = NO;
    for (VibeFXStageIndex i = VibeFXStageDelay; i <= VibeFXStageShortDelay; i++) {
        VibeFXStage *stage = &chain->stages[i];
        if (!atomic_load_explicit(&stage->active, memory_order_seq_cst)) {
            continue;
        }
        VibeFXUnit *half = &chain->units[stage->firstUnit];
        VibeFXUnit *left = half + 1;
        VibeFXUnit *right = half + 2;
        VibeFXGate(stage, out, chain->send, frames, chain->slewPerFrame);
        if ((status = VibeFXRenderUnit(chain, half, timestamp, frames, chain->halfTap)) != noErr) {
            return status;
        }
        // The right lane, panned right at one hop of decay: it first sounds at
        // 2T, a full hop after the left lane's T.
        if ((status = VibeFXRenderUnit(chain, right, timestamp, frames, chain->lane)) != noErr) {
            return status;
        }
        VibeFXPanInto(chain->lane, chain->echoes, frames, kDelayPingPongPan, kDelayFeedbackPercent / 100.0f, echoes);
        echoes = YES;
        // The left lane, fed by the half-tap lane, summed with it and panned left.
        if ((status = VibeFXRenderUnit(chain, left, timestamp, frames, chain->lane)) != noErr) {
            return status;
        }
        VibeFXAdd(chain->lane, chain->halfTap, frames);
        VibeFXPanInto(chain->lane, chain->echoes, frames, -kDelayPingPongPan, 1.0f, YES);
    }
    if (echoes) {
        if ((status = VibeFXRenderUnit(chain, &chain->units[VibeFXUnitDelayLowCut], timestamp, frames, chain->lane)) != noErr) {
            return status;
        }
        if (returns) {
            VibeFXAdd(chain->returns, chain->lane, frames);
        }
        else {
            VibeFXCopy(chain->returns, chain->lane, frames);
            returns = YES;
        }
    }
    if (returns) {
        VibeFXAdd(out, chain->returns, frames);
    }
    return status;
}
VIBE_REALTIME_END

#pragma mark - Hosting

BOOL VibeHostAudioUnit(AudioUnit *unit, OSType type, OSType subtype, const AudioStreamBasicDescription *format,
                       UInt32 maximumFrameCount, AURenderCallbackStruct input, void (^configure)(AudioUnit)) {
    VibeDisposeAudioUnit(unit);
    AudioComponentDescription description = {
        .componentType = type, .componentSubType = subtype, .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit instance = NULL;
    if (!component || AudioComponentInstanceNew(component, &instance) != noErr || !instance) {
        LogError(@"AudioFX: no '%c%c%c%c' unit", (char)(subtype >> 24), (char)(subtype >> 16), (char)(subtype >> 8), (char)subtype);
        return NO;
    }
    AudioStreamBasicDescription asbd = *format;
    UInt32 frames = maximumFrameCount;
    OSStatus status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (status == noErr) {
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));
    }
    if (status == noErr) {
        // TRAP: a directly hosted Apple unit defaults to 1156 frames per slice
        // and refuses the pipeline's 4096-frame slices with
        // kAudioUnitErr_TooManyFramesToProcess.
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, sizeof(input));
    }
    if (status == noErr && configure) {
        configure(instance);
    }
    if (status == noErr) {
        status = AudioUnitInitialize(instance);
    }
    if (status != noErr) {
        LogError(@"AudioFX: hosting '%c%c%c%c' failed (OSStatus %d)", (char)(subtype >> 24), (char)(subtype >> 16),
                 (char)(subtype >> 8), (char)subtype, (int)status);
        AudioComponentInstanceDispose(instance);
        return NO;
    }
    *unit = instance;
    return YES;
}

void VibeDisposeAudioUnit(AudioUnit *unit) {
    if (*unit) {
        AudioUnitUninitialize(*unit);
        AudioComponentInstanceDispose(*unit);
        *unit = NULL;
    }
}

double VibeAudioUnitSeconds(AudioUnit unit, AudioUnitPropertyID property) {
    Float64 value = 0;
    UInt32 size = sizeof(value);
    if (!unit || AudioUnitGetProperty(unit, property, kAudioUnitScope_Global, 0, &value, &size) != noErr) {
        return 0;
    }
    return value;
}

// Copies the scratch into the buffer the unit allocated for itself. TRAP:
// never set kAudioUnitProperty_ShouldAllocateBuffer to 0: a unit handed the
// scratch itself (AUDelay, measured) writes its output back into it, so a
// lane reading that scratch after the unit reads the unit's output.
static OSStatus VibeFXInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    VibeFXUnit *unit = refCon;
    UInt32 buffers = data->mNumberBuffers < 2 ? data->mNumberBuffers : 2;
    for (UInt32 c = 0; c < buffers; c++) {
        if (!data->mBuffers[c].mData) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        memcpy(data->mBuffers[c].mData, unit->source[c], frames * sizeof(float));
        data->mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
    }
    return noErr;
}

static void VibeFXSetParameter(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitParameterValue value) {
    OSStatus status = AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0);
    if (status != noErr) {
        LogWarn(@"AudioFX: parameter %u = %g refused (OSStatus %d)", (unsigned)parameter, value, (int)status);
    }
}

// How long a unit keeps sounding after its input stopped, plus its latency.
static double VibeFXTailSeconds(AudioUnit unit) {
    return VibeAudioUnitSeconds(unit, kAudioUnitProperty_TailTime) + VibeAudioUnitSeconds(unit, kAudioUnitProperty_Latency);
}

// Hosts one of the chain's units over `source` (NULL for the EQ, whose
// source the render points at its buffers), the input callback copying.
static BOOL VibeFXHostUnit(VibeFXUnit *unit, OSType type, OSType subtype, const AudioStreamBasicDescription *format,
                           UInt32 maxFrames, float *const _Nullable * _Nullable source, void (^ _Nullable configure)(AudioUnit)) {
    unit->source[0] = source ? source[0] : NULL;
    unit->source[1] = source ? source[1] : NULL;
    AURenderCallbackStruct input = { .inputProc = VibeFXInput, .inputProcRefCon = unit };
    return VibeHostAudioUnit(&unit->unit, type, subtype, format, maxFrames, input, configure);
}

// A one-band high-pass return filter, the tail and echo low-cuts.
static BOOL VibeFXHostLowCut(VibeFXUnit *unit, const AudioStreamBasicDescription *format, UInt32 maxFrames,
                             float *const source[2], float cutoffHz) {
    BOOL hosted = VibeFXHostUnit(unit, kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ, format, maxFrames, source, ^(AudioUnit instance) {
        UInt32 bands = 1;
        AudioUnitSetProperty(instance, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, sizeof(bands));
    });
    if (hosted) {
        VibeFXSetParameter(unit->unit, kAUNBandEQParam_FilterType, kAUNBandEQFilterType_2ndOrderButterworthHighPass);
        VibeFXSetParameter(unit->unit, kAUNBandEQParam_Frequency, cutoffHz);
        VibeFXSetParameter(unit->unit, kAUNBandEQParam_BypassBand, 0);
    }
    return hosted;
}

// A 100%-wet delay line.
static BOOL VibeFXHostDelay(VibeFXUnit *unit, const AudioStreamBasicDescription *format, UInt32 maxFrames,
                            float *const source[2], float feedbackPercent, NSTimeInterval seconds) {
    BOOL hosted = VibeFXHostUnit(unit, kAudioUnitType_Effect, kAudioUnitSubType_Delay, format, maxFrames, source, nil);
    if (hosted) {
        VibeFXSetParameter(unit->unit, kDelayParam_WetDryMix, 100);
        VibeFXSetParameter(unit->unit, kDelayParam_Feedback, feedbackPercent);
        VibeFXSetParameter(unit->unit, kDelayParam_DelayTime, (float)seconds);
    }
    return hosted;
}

static void VibeFXStageSet(VibeFXStage *stage, VibeFXUnitIndex firstUnit, int unitCount, float level, float swellRatio) {
    stage->firstUnit = firstUnit;
    stage->unitCount = unitCount;
    stage->level = level;
    stage->swellRatio = swellRatio;
}

static void VibeFXChainFree(VibeFXChain *chain) {
    for (int i = 0; i < VibeFXUnitCount; i++) {
        VibeDisposeAudioUnit(&chain->units[i].unit);
    }
    free(chain->storage);
    free(chain);
}

// Rests a stage the queue took out of the render, once the render has left
// it: its gate's gain and its units forget their state, so its next engage
// starts from silence — or, for the low kill, from an exact identity. A
// stage engaged again in the meantime is left as it is. The delays' shared
// low-cut rests with the last of them.
static void VibeFXRestStage(VibeFXChain *chain, VibeFXStage *stage) {
    if (atomic_load_explicit(&stage->active, memory_order_seq_cst)) {
        return;
    }
    stage->gain = 0;
    for (int u = 0; u < stage->unitCount; u++) {
        if (chain->units[stage->firstUnit + u].unit) {
            AudioUnitReset(chain->units[stage->firstUnit + u].unit, kAudioUnitScope_Global, 0);
        }
    }
    VibeFXStage *delays = &chain->stages[VibeFXStageDelay];
    if (stage >= delays && stage <= delays + 1
            && !atomic_load_explicit(&delays[0].active, memory_order_seq_cst)
            && !atomic_load_explicit(&delays[1].active, memory_order_seq_cst)
            && chain->units[VibeFXUnitDelayLowCut].unit) {
        AudioUnitReset(chain->units[VibeFXUnitDelayLowCut].unit, kAudioUnitScope_Global, 0);
    }
}

@implementation AudioFX {
    void (^_scheduler)(NSTimeInterval, dispatch_block_t);
    void (^_afterRenderLeaves)(dispatch_block_t);
    // The player's queue: all hosting and parameter mutation.
    dispatch_queue_t        _queue;
    // Guards the intent flags and delayTapBPM. The ramp generations are
    // queue-confined and need no lock.
    os_unfair_lock          _stateLock;
    // The stages (the intent and the gates, which the scheduled ramps point
    // into) and the render counter, for the object's life; _chain is their
    // current hosting, NULL while unhosted.
    VibeFXStage             _stages[VibeFXStageCount];
    _Atomic uint64_t        _unitRenders;
    VibeFXChain             *_chain;
    BOOL                    _connected;

    // The intent is lock-guarded; the rest is queue-confined. The frequency
    // and the flat flag shadow what the unit was last told, so a sweep starts
    // where the filter sits.
    BOOL                    _lowKillEnabled;
    BOOL                    _lowKillBoostActive;
    uint64_t                _lowKillRampGeneration;
    float                   _lowKillFrequency;
    BOOL                    _lowKillFlat;

    // Lock-guarded. The sends' intent lives in their stages.
    float                   _delayTapBPM;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(void (^)(NSTimeInterval, dispatch_block_t))scheduler
            afterRenderLeaves:(void (^)(dispatch_block_t))afterRenderLeaves {
    self = [super init];
    if (self) {
        _queue = queue;
        _scheduler = [scheduler copy];
        _afterRenderLeaves = [afterRenderLeaves copy];
        _stateLock = OS_UNFAIR_LOCK_INIT;
        VibeFXStageSet(&_stages[VibeFXStageLowKill], VibeFXUnitEQ, 1, 0, 0);
        VibeFXStageSet(&_stages[VibeFXStageReverb], VibeFXUnitReverb, 2, kReverbSendLevel, kReverbSwellRatio);
        VibeFXStageSet(&_stages[VibeFXStageDelay], VibeFXUnitHalf0, 3, kDelaySendLevel, kDelaySwellRatio);
        VibeFXStageSet(&_stages[VibeFXStageShortDelay], VibeFXUnitHalf1, 3, kDelaySendLevel, kDelaySwellRatio);
        _lowKillFrequency = kLowKillParkedHz;
        _lowKillFlat = YES;
    }
    return self;
}

- (void)dealloc {
    [self retireChain];
}

- (VibeFXChain *)chain {
    return _chain;
}

- (BOOL)connected {
    return _connected;
}

- (BOOL)sendsActive {
    VibeFXChain *chain = _chain;
    for (int i = VibeFXStageReverb; chain && i < VibeFXStageCount; i++) {
        if (atomic_load_explicit(&chain->stages[i].active, memory_order_seq_cst)) {
            return YES;
        }
    }
    return NO;
}

- (NSTimeInterval)longestTailSeconds {
    VibeFXChain *chain = _chain;
    NSTimeInterval longest = 0;
    for (int i = VibeFXStageReverb; chain && i < VibeFXStageCount; i++) {
        longest = MAX(longest, chain->stages[i].tailSeconds);
    }
    return longest;
}

- (uint64_t)unitRenders {
    return atomic_load_explicit(&_unitRenders, memory_order_relaxed);
}

- (BOOL)hosted {
    return _chain != NULL;
}

- (NSUInteger)hostedUnitCount {
    VibeFXChain *chain = _chain;
    NSUInteger count = 0;
    for (int i = 0; chain && i < VibeFXUnitCount; i++) {
        count += chain->units[i].unit != NULL;
    }
    return count;
}

#if DEBUG
- (BOOL)debugUninitializeUnitAtIndex:(NSUInteger)index {
    VibeFXChain *chain = _chain;
    if (!chain || index >= VibeFXUnitCount || !chain->units[index].unit) {
        return NO;
    }
    return AudioUnitUninitialize(chain->units[index].unit) == noErr;
}
#endif

- (NSDictionary<NSString *, id> *)diagnosticSnapshot {
    VibeFXChain *chain = _chain;
    os_unfair_lock_lock(&_stateLock);
    BOOL lowKill = _lowKillEnabled, boost = _lowKillBoostActive;
    float bpm = _delayTapBPM;
    BOOL enabled[VibeFXStageCount];
    for (int i = 0; i < VibeFXStageCount; i++) {
        enabled[i] = _stages[i].enabled;
    }
    os_unfair_lock_unlock(&_stateLock);
    NSString *names[VibeFXStageCount] = { @"lowKill", @"reverb", @"delay", @"shortDelay" };
    NSMutableDictionary *stages = [NSMutableDictionary dictionary];
    for (int i = 0; i < VibeFXStageCount; i++) {
        VibeFXStage *stage = &_stages[i];
        stages[names[i]] = @{
            @"enabled": @(i == VibeFXStageLowKill ? lowKill : enabled[i]),
            @"active": @(atomic_load_explicit(&stage->active, memory_order_relaxed) != 0),
            @"gateTarget": @(atomic_load_explicit(&stage->target, memory_order_relaxed)),
            @"tailSeconds": @(stage->tailSeconds),
        };
    }
    return @{
        @"connected": @(_connected),
        @"hosted": @(self.hosted),
        @"hostedUnits": @(self.hostedUnitCount),
        @"sampleRate": @(chain ? chain->sampleRate : 0),
        @"maximumFrames": @(chain ? chain->maxFrames : 0),
        // The dry path's: the low kill's EQ is the one unit the signal passes
        // through rather than beside, so its declared latency is the segment's.
        @"latencySeconds": @(chain && chain->units[VibeFXUnitEQ].unit
                             ? VibeAudioUnitSeconds(chain->units[VibeFXUnitEQ].unit, kAudioUnitProperty_Latency) : 0),
        @"unitRenders": @(self.unitRenders),
        @"lowKillBoost": @(boost),
        @"lowKillFrequency": @(_lowKillFrequency),
        @"lowKillFlat": @(_lowKillFlat),
        @"delayTapBPM": @(bpm),
        @"stages": stages,
    };
}

#pragma mark - Connecting

- (void)setConnected:(BOOL)connected format:(nullable AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount {
    if (!connected) {
        [self disconnectOnQueue];
        return;
    }
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved && format.channelCount == 2);
    if (self.hosted && (_chain->sampleRate != format.sampleRate || _chain->maxFrames != maximumFrameCount)) {
        // An effect cannot convert between its input and output rates: host
        // again, and re-apply the intent below.
        [self disconnectOnQueue];
        [self retireChain];
    }
    if (!self.hosted && ![self hostUnitsWithFormat:format maximumFrameCount:maximumFrameCount]) {
        [self retireChain];
        return;
    }
    if (_connected) {
        return;
    }
    _connected = YES;
    // Intent recorded before the chain existed.
    [self applyLowKillTargetOnQueue];
    [self applyDelayTapOnQueue];
    for (VibeFXStageIndex i = VibeFXStageReverb; i < VibeFXStageCount; i++) {
        VibeFXStage *stage = &_stages[i];
        os_unfair_lock_lock(&_stateLock);
        BOOL on = stage->enabled;
        os_unfair_lock_unlock(&_stateLock);
        if (on) {
            [self applySendGateOnQueue:stage enabled:YES];
        }
    }
}

// The player withdrew the chain from the render first. Every tail and sweep
// leaves at once, nothing is written to the units until the next connect,
// and the stages rest once a render already inside has left.
- (void)disconnectOnQueue {
    if (!_connected) {
        return;
    }
    _connected = NO;
    _lowKillRampGeneration++;
    for (int i = 0; i < VibeFXStageCount; i++) {
        VibeFXStage *stage = &_stages[i];
        stage->generation++;
        atomic_store_explicit(&stage->active, 0, memory_order_seq_cst);
        atomic_store_explicit(&stage->target, 0, memory_order_relaxed);
    }
    [self setLowKillBandsFlat:YES];
    [self setLowKillFrequency:kLowKillParkedHz];
    VibeFXChain *chain = _chain;
    _afterRenderLeaves(^{
        for (int i = 0; i < VibeFXStageCount; i++) {
            VibeFXRestStage(chain, &chain->stages[i]);
        }
    });
}

// The hosting leaves the object now and is freed once the render has left it.
- (void)retireChain {
    VibeFXChain *chain = _chain;
    if (!chain) {
        return;
    }
    _chain = NULL;
    _afterRenderLeaves(^{ VibeFXChainFree(chain); });
}

// Parked: the low kill flat, the gates closed, the default tempo. NO leaves
// the failed hosting for retireChain.
- (BOOL)hostUnitsWithFormat:(AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount {
    VibeFXChain *chain = calloc(1, sizeof(VibeFXChain));
    if (!chain) {
        return NO;
    }
    _chain = chain;
    chain->stages = _stages;
    chain->unitRenders = &_unitRenders;
    chain->storage = calloc((size_t)maximumFrameCount * 12, sizeof(float));
    if (!chain->storage) {
        return NO;
    }
    // TRAP: vDSP_vclr, not memset: clang drops a memset(0) after calloc (AudioVoiceBus's pre-touch).
    vDSP_vclr(chain->storage, 1, (vDSP_Length)maximumFrameCount * 12);
    float **pairs[] = { chain->send, chain->wet, chain->halfTap, chain->lane, chain->echoes, chain->returns };
    for (size_t p = 0; p < 6; p++) {
        pairs[p][0] = chain->storage + (p * 2) * maximumFrameCount;
        pairs[p][1] = chain->storage + (p * 2 + 1) * maximumFrameCount;
    }
    chain->sampleRate = format.sampleRate;
    chain->maxFrames = maximumFrameCount;
    chain->slewPerFrame = (float)(1.0 / (kGateSlewSeconds * format.sampleRate));
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    VibeFXUnit *units = chain->units;

    // Both bands stay un-bypassed for the chain's life (kLowKillParkedHz).
    BOOL hosted = VibeFXHostUnit(&units[VibeFXUnitEQ], kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ, asbd, maximumFrameCount, NULL,
                                 ^(AudioUnit instance) {
        UInt32 bands = 2;
        AudioUnitSetProperty(instance, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, sizeof(bands));
    });
    if (hosted) {
        _lowKillFlat = NO; // so the swap below writes the bands
        [self setLowKillBandsFlat:YES];
        [self setLowKillFrequency:kLowKillParkedHz];
        for (UInt32 band = 0; band < 2; band++) {
            VibeFXSetParameter(units[VibeFXUnitEQ].unit, kAUNBandEQParam_BypassBand + band, 0);
        }
    }

    // Fully wet: the dry signal only travels the dry path. macOS only.
#if TARGET_OS_OSX
    hosted = hosted && VibeFXHostUnit(&units[VibeFXUnitReverb], kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb, asbd, maximumFrameCount,
                                      chain->send, ^(AudioUnit instance) {
        AUPreset preset = { .presetNumber = kReverbCathedralPreset, .presetName = NULL };
        AudioUnitSetProperty(instance, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, sizeof(preset));
    });
    if (hosted) {
        VibeFXSetParameter(units[VibeFXUnitReverb].unit, kReverbParam_DryWetMix, 100);
        VibeFXSetParameter(units[VibeFXUnitReverb].unit, kReverbParam_SmallLargeMix, kReverbSmallLargeMix);
        VibeFXSetParameter(units[VibeFXUnitReverb].unit, kReverbParam_LargeSize, kReverbLargeSize);
        VibeFXSetParameter(units[VibeFXUnitReverb].unit, kReverbParam_LargeDensity, kReverbLargeDensity);
    }
#else
    hosted = NO;
#endif
    hosted = hosted && VibeFXHostLowCut(&units[VibeFXUnitReverbLowCut], asbd, maximumFrameCount, chain->wet, kReverbTailLowCutHz);
    hosted = hosted && VibeFXHostLowCut(&units[VibeFXUnitDelayLowCut], asbd, maximumFrameCount, chain->echoes, kDelayEchoLowCutHz);

    // See the topology comment.
    float laneFeedbackPercent = VibeDelayLaneFeedbackPercent(kDelayFeedbackPercent);
    for (VibeFXStageIndex i = VibeFXStageDelay; i <= VibeFXStageShortDelay && hosted; i++) {
        float beatsPerTap = i == VibeFXStageDelay ? kDelayTapBeats : kShortDelayTapBeats;
        VibeFXUnit *half = &units[chain->stages[i].firstUnit];
        hosted = VibeFXHostDelay(half, asbd, maximumFrameCount, chain->send, 0, VibeDelayTapSeconds(0, beatsPerTap))
                && VibeFXHostDelay(half + 1, asbd, maximumFrameCount, chain->halfTap, laneFeedbackPercent, VibeDelayLaneSeconds(0, beatsPerTap))
                && VibeFXHostDelay(half + 2, asbd, maximumFrameCount, chain->send, laneFeedbackPercent, VibeDelayLaneSeconds(0, beatsPerTap));
    }
    if (!hosted) {
        return NO;
    }
    // The tails that never move: the reverb's, and the return filters'. The
    // delays' follow the tap.
    chain->stages[VibeFXStageReverb].tailSeconds = VibeFXTailSeconds(units[VibeFXUnitReverb].unit)
            + VibeFXTailSeconds(units[VibeFXUnitReverbLowCut].unit);
    chain->delayLowCutTail = VibeFXTailSeconds(units[VibeFXUnitDelayLowCut].unit);
    [self readDelayTailsOnQueue];
    LogDebug(@"AudioFX: hosted %lu units at %.0f Hz", (unsigned long)self.hostedUnitCount, format.sampleRate);
    return YES;
}

// How long each delay stage keeps rendering after its gate closes: the
// longest of its lanes' tails plus the shared return filter's. Re-read
// whenever a delay time moves.
- (void)readDelayTailsOnQueue {
    VibeFXChain *chain = _chain;
    if (!chain) {
        return;
    }
    for (VibeFXStageIndex i = VibeFXStageDelay; i <= VibeFXStageShortDelay; i++) {
        VibeFXStage *stage = &chain->stages[i];
        double tail = 0;
        for (int u = 0; u < stage->unitCount; u++) {
            tail = MAX(tail, VibeFXTailSeconds(chain->units[stage->firstUnit + u].unit));
        }
        stage->tailSeconds = tail + chain->delayLowCutTail;
    }
}

// The stage leaves the render now, and forgets its state once the render
// has left it (VibeFXRestStage), so the next engage starts from silence — or,
// for the low kill, from an exact identity.
- (void)restStageOnQueue:(VibeFXStage *)stage {
    if (!atomic_load_explicit(&stage->active, memory_order_relaxed)) {
        return;
    }
    atomic_store_explicit(&stage->active, 0, memory_order_seq_cst);
    VibeFXChain *chain = _chain;
    _afterRenderLeaves(^{ VibeFXRestStage(chain, stage); });
}

#pragma mark - Low kill

- (BOOL)lowKillEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _lowKillEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setLowKillEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_lowKillEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _lowKillEnabled = enabled;
    // The boost modifies the low kill rather than being a control of its own,
    // so killing the filter kills the boost with it. Otherwise a latched W
    // would hold the cutoff above where Q alone would put it while the low
    // kill read off. It is cleared under the same lock, so the one sweep below
    // resolves both rather than racing a second one.
    if (!enabled) {
        _lowKillBoostActive = NO;
    }
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyLowKillTargetOnQueue];
    });
}

- (BOOL)lowKillBoostActive {
    os_unfair_lock_lock(&_stateLock);
    BOOL active = _lowKillBoostActive;
    os_unfair_lock_unlock(&_stateLock);
    return active;
}

- (void)setLowKillBoostActive:(BOOL)active {
    os_unfair_lock_lock(&_stateLock);
    if (_lowKillBoostActive == active) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _lowKillBoostActive = active;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyLowKillTargetOnQueue];
    });
}

// Sweeps from wherever the filter sits to VibeLowKillCutoffHz; a re-toggle
// preempts through the generation and continues from there. "Off" sweeps to
// the floor, swaps the bands flat (colorless), and once settled resets and
// skips the unit (free). Bypass is never touched (kLowKillParkedHz).
- (void)applyLowKillTargetOnQueue {
    if (!self.hosted || !_connected) {
        return; // Not hosted yet. The first connect re-applies this.
    }
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _lowKillEnabled;
    BOOL boost = _lowKillBoostActive;
    os_unfair_lock_unlock(&_stateLock);
    float target = VibeLowKillCutoffHz(enabled, boost);
    if (target == _lowKillFrequency && _lowKillFlat == (target == kLowKillParkedHz)) {
        return; // Already there — a fresh host, or a re-applied intent; a pending settle keeps its generation.
    }
    uint64_t generation = ++_lowKillRampGeneration;
    if (target != kLowKillParkedHz) {
        // A reset, parked unit passes the signal exactly, so joining the
        // render here is seamless; then re-arm at the floor and sweep up.
        atomic_store_explicit(&_stages[VibeFXStageLowKill].active, 1, memory_order_seq_cst);
        [self setLowKillBandsFlat:NO];
    }
    [self stepLowKillRamp:1 from:_lowKillFrequency to:target generation:generation];
}

// Flat is a 0 dB parametric band, an identity biquad. The swap keeps the filter
// state, so the old response decays without a discontinuity. Idempotent: a
// repeated swap would restart that decay.
- (void)setLowKillBandsFlat:(BOOL)flat {
    if (flat == _lowKillFlat) {
        return;
    }
    _lowKillFlat = flat;
    AudioUnit unit = _chain ? _chain->units[VibeFXUnitEQ].unit : NULL;
    if (!unit) {
        return;
    }
    if (flat) {
        for (UInt32 band = 0; band < 2; band++) {
            VibeFXSetParameter(unit, kAUNBandEQParam_FilterType + band, kAUNBandEQFilterType_Parametric);
            VibeFXSetParameter(unit, kAUNBandEQParam_Gain + band, 0);
            VibeFXSetParameter(unit, kAUNBandEQParam_Bandwidth + band, kLowKillFlatBandwidth);
        }
        return;
    }
    VibeFXSetParameter(unit, kAUNBandEQParam_FilterType, kAUNBandEQFilterType_ResonantHighPass);
    VibeFXSetParameter(unit, kAUNBandEQParam_Bandwidth, kLowKillResonanceBandwidth);
    VibeFXSetParameter(unit, kAUNBandEQParam_FilterType + 1, kAUNBandEQFilterType_2ndOrderButterworthHighPass);
}

// Both cascaded bands track the same frequency.
- (void)setLowKillFrequency:(float)frequency {
    _lowKillFrequency = frequency;
    AudioUnit unit = _chain ? _chain->units[VibeFXUnitEQ].unit : NULL;
    for (UInt32 band = 0; unit && band < 2; band++) {
        VibeFXSetParameter(unit, kAUNBandEQParam_Frequency + band, frequency);
    }
}

// Log-frequency steps, each the same musical interval. Landing at the floor
// parks the bands flat and, after the settle, rests the unit.
- (void)stepLowKillRamp:(int)step from:(float)start to:(float)target generation:(uint64_t)generation {
    if (generation != _lowKillRampGeneration) {
        return; // A newer toggle owns the cutoff now.
    }
    float frequency = (step >= kLowKillSweepSteps)
            ? target
            : start * powf(target / start, (float)step / (float)kLowKillSweepSteps);
    [self setLowKillFrequency:frequency];
    __weak AudioFX *weakSelf = self;
    if (step >= kLowKillSweepSteps) {
        if (target == kLowKillParkedHz) {
            [self setLowKillBandsFlat:YES]; // Landed at the floor: go colorless.
            _scheduler(kLowKillSettleSeconds, ^{
                AudioFX *strongSelf = weakSelf;
                if (strongSelf && generation == strongSelf->_lowKillRampGeneration) {
                    [strongSelf restStageOnQueue:&strongSelf->_stages[VibeFXStageLowKill]];
                }
            });
        }
        return;
    }
    _scheduler(kLowKillSweepStepMicroseconds / 1000000.0, ^{
        [weakSelf stepLowKillRamp:step + 1 from:start to:target generation:generation];
    });
}

#pragma mark - The sends

- (BOOL)sendEnabled:(VibeFXStageIndex)index {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _stages[index].enabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setSend:(VibeFXStageIndex)index enabled:(BOOL)enabled {
    VibeFXStage *stage = &_stages[index];
    os_unfair_lock_lock(&_stateLock);
    if (stage->enabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    stage->enabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applySendGateOnQueue:stage enabled:enabled];
    });
}

- (BOOL)reverbSendEnabled { return [self sendEnabled:VibeFXStageReverb]; }
- (void)setReverbSendEnabled:(BOOL)enabled { [self setSend:VibeFXStageReverb enabled:enabled]; }
- (BOOL)delaySendEnabled { return [self sendEnabled:VibeFXStageDelay]; }
- (void)setDelaySendEnabled:(BOOL)enabled { [self setSend:VibeFXStageDelay enabled:enabled]; }
- (BOOL)shortDelaySendEnabled { return [self sendEnabled:VibeFXStageShortDelay]; }
- (void)setShortDelaySendEnabled:(BOOL)enabled { [self setSend:VibeFXStageShortDelay enabled:enabled]; }

// Opening is a declick-length fade, then a slow swell while held. Closing cuts
// only the send: the stage renders its tail, then rests. A re-toggle preempts
// through the generation from the current level.
- (void)applySendGateOnQueue:(VibeFXStage *)stage enabled:(BOOL)enabled {
    if (!self.hosted || !_connected) {
        return; // Not hosted yet. The first connect re-applies it.
    }
    uint64_t generation = ++stage->generation;
    float from = atomic_load_explicit(&stage->target, memory_order_relaxed);
    if (!enabled) {
        [self stepSendGateRamp:stage step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                          from:from to:0 generation:generation completion:nil];
        return;
    }
    // A resting stage joins the render before its gate opens; reset, it
    // starts from silence under the gate's fade-in.
    atomic_store_explicit(&stage->active, 1, memory_order_seq_cst);
    __weak AudioFX *weakSelf = self;
    float level = stage->level;
    float swell = VibeSendSwellLevel(level, stage->swellRatio);
    [self stepSendGateRamp:stage step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                      from:from to:level generation:generation completion:^{
        // Same generation, so a release preempts the swell too.
        [weakSelf stepSendGateRamp:stage step:1 of:kSendSwellSteps stepMicroseconds:kSendSwellStepMicroseconds
                              from:level to:swell generation:generation completion:nil];
    }];
}

// stage lives for the object's life, so the pointer cannot dangle. The
// completion fires only on an un-preempted run to the target: a preempted
// ramp's owner has moved on, and its follow-up must not start. A ramp that
// closes the gate schedules the stage's rest for after its tail.
- (void)stepSendGateRamp:(VibeFXStage *)stage step:(int)step of:(int)steps stepMicroseconds:(uint64_t)stepMicroseconds from:(float)start to:(float)target generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    if (generation != stage->generation) {
        return; // A newer toggle owns the gate now.
    }
    __weak AudioFX *weakSelf = self;
    if (step >= steps) {
        atomic_store_explicit(&stage->target, target, memory_order_relaxed);
        if (completion) {
            completion();
        }
        else if (target == 0) {
            _scheduler(stage->tailSeconds, ^{
                AudioFX *strongSelf = weakSelf;
                if (strongSelf && generation == stage->generation) {
                    [strongSelf restStageOnQueue:stage];
                }
            });
        }
        return;
    }
    atomic_store_explicit(&stage->target, VibeFadeVolumeOverSteps(start, target, step, steps), memory_order_relaxed);
    _scheduler(stepMicroseconds / 1000000.0, ^{
        [weakSelf stepSendGateRamp:stage step:step + 1 of:steps stepMicroseconds:stepMicroseconds from:start to:target generation:generation completion:completion];
    });
}

- (float)delayTapBPM {
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    return bpm;
}

- (void)setDelayTapBPM:(float)bpm {
    os_unfair_lock_lock(&_stateLock);
    if (_delayTapBPM == bpm) {
        os_unfair_lock_unlock(&_stateLock);
        return; // Called on every fader tick, so only real changes touch the queue.
    }
    _delayTapBPM = bpm;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyDelayTapOnQueue];
    });
}

// Post-varispeed, so tap time is wall-clock at the effective tempo.
- (void)applyDelayTapOnQueue {
    if (!self.hosted || !_connected) {
        return; // Not in the chain. The next connect re-applies it.
    }
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    for (VibeFXStageIndex i = VibeFXStageDelay; i <= VibeFXStageShortDelay; i++) {
        float beatsPerTap = i == VibeFXStageDelay ? kDelayTapBeats : kShortDelayTapBeats;
        float lane = (float)VibeDelayLaneSeconds(bpm, beatsPerTap);
        VibeFXUnit *half = &_chain->units[_stages[i].firstUnit];
        VibeFXSetParameter(half->unit, kDelayParam_DelayTime, (float)VibeDelayTapSeconds(bpm, beatsPerTap));
        VibeFXSetParameter((half + 1)->unit, kDelayParam_DelayTime, lane);
        VibeFXSetParameter((half + 2)->unit, kDelayParam_DelayTime, lane);
    }
    [self readDelayTailsOnQueue];
}

@end
