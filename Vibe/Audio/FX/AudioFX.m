//
//  AudioFX.m
//  Vibe
//

#import "AudioFX.h"
#import "AudioFXMath.h" // the cutoff, tap and swell arithmetic, tested separately
#import "FadeMath.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <unistd.h>

// The low-kill cutoffs and the default tap tempo are in AudioFXMath.h, with
// the functions that resolve them. The EQ runs two cascaded high-pass bands
// swept together, 12 dB/oct each for 24 dB/oct in total — a resonant one
// carrying a small DJ-filter bump at the cutoff, plus a plain 2nd-order
// Butterworth.
//
// Resonance of the resonant band, as AUNBandEQ bandwidth in octaves, where
// narrower is peakier. A touch of squelch at the cutoff, not a scream.
static const float kLowKillResonanceBandwidth = 0.7f;
// Bandwidth of the parked bands. A 0 dB parametric band is an identity filter
// whatever its bandwidth, so this only shapes how the old response's residue
// dies after the swap: two octaves is a hair over critically damped, settling
// in ~60ms without a ring. At the resonant bandwidth the residue rang at 20 Hz
// for ~250ms instead.
static const float kLowKillFlatBandwidth = 2.0f;
// Sweep resolution, much finer than the volume fades. Coefficient jumps big
// enough to hear as zipper or click need small steps, and a slightly longer
// total sweep of about 80ms still reads as an instant kill.
static const int kLowKillSweepSteps = 40;
static const uint64_t kLowKillSweepStepMicroseconds = 2000;
// How long a parked EQ keeps rendering after its sweep landed flat, for the
// residue above to die out, before it is reset and skipped.
static const NSTimeInterval kLowKillSettleSeconds = 0.25;

// Momentary reverb send, on a held E key. The master signal is tapped
// post-low-kill into a gated, 100%-wet parallel reverb return, so releasing
// the key cuts the send while the tail rings out naturally. This gate level
// while engaged is the wet-dry balance, since the dry path always runs at
// unity, so anything below 0.5 keeps the verb sitting under the dry signal.
static const float kReverbSendLevel = 0.3f;
// High-pass on the reverb output, so the tail cannot muddy the bass.
// Filtering the return rather than the send guarantees that even the ringing
// tail is low-cut.
static const float kReverbTailLowCutHz = 550.0f;
#if TARGET_OS_OSX
// MatrixReverb tuning, applied on top of the Cathedral preset; Reverb2 sounds
// thin and digital by comparison. CAUTION: the ranges documented in
// AudioUnitParameters.h are stale. The AU's real LargeSize range, queried
// through kAudioUnitProperty_ParameterInfo, is 0.005-0.15, not the header's
// "0.4->10.0 Secs", and an out-of-range value asserts in the render thread
// through caulk CAVerboseAbort, killing the app on first play. MatrixReverb
// has no decay-seconds knob at all, so the size, mix and density maxed out
// below give the longest tail this engine does. Cathedral ships at LargeSize
// 0.06 and mix 35.
static const float kReverbLargeSize = 0.15f;     // the real max: the tail knob
static const float kReverbSmallLargeMix = 90.0f; // 0-100: mostly the large hall engine
static const float kReverbLargeDensity = 0.9f;   // lush, smooth tail
static const SInt32 kReverbCathedralPreset = 8;  // MatrixReverb's factory preset list, read at host
#endif

// Momentary delay echo sends, on held R and T keys, using the same gated
// send-return pattern as the reverb. The tap is a fraction of a beat of the
// effective, pitch-scaled tempo. The controller feeds delayTapBPM from the
// same tagged or detected BPM the label shows, and with no tempo known the
// default below applies. R and T are the same machine at different clock
// divisions:
static const float kDelayTapBeats = 0.5f;       // R: 1/8 note, half a beat
static const float kShortDelayTapBeats = 0.25f; // T: 1/16 note, a quarter beat
static const float kDelaySendLevel = 0.3f;
// Per-hop echo decay, where L->R counts as one hop. The ping-pong lanes run
// at twice the tap period, as the topology comment explains, so each lane's
// own feedback is this squared.
static const float kDelayFeedbackPercent = 75.0f; // aggressive: a long trail of repeats
// High-pass on the delay output. Every repeat re-exits through it, so the
// echoes never pile up bass under the dry signal. AUDelay's own in-loop
// filter is lowpass-only, so the cut lives on the return instead.
static const float kDelayEchoLowCutHz = 450.0f;
// Ping-pong width: echoes alternate sides at half pan, not hard left and right.
static const float kDelayPingPongPan = 0.5f;

// After a send's fast open, it keeps swelling gently while the key stays held,
// so the effect builds the longer it is ridden, like easing a send fader up.
// The ratio multiplies the base level over six seconds, in steps small enough
// — about 0.5% each — to be seamless. Releasing the key still closes fast, on
// the normal fade cadence.
static const float kReverbSwellRatio = 1.8f; // 0.3 -> 0.54
static const float kDelaySwellRatio = 1.8f;  // 0.3 -> 0.54
static const int kSendSwellSteps = 120;
static const uint64_t kSendSwellStepMicroseconds = 50000; // 120 x 50ms = 6s

// The slew a gate's gain moves at on the audio thread: full scale in about
// 25 ms, what AVAudioMixerNode's volume measured through offline rendering,
// so the queue's millisecond steps reach the output as they did through the
// mixer.
static const double kGateSlewSeconds = 0.025;
// A stage is reset only once no render is inside the chain; this bounds the
// wait, as the output unit's stop does.
static const useconds_t kDrainSpinMicroseconds = 200;
static const int kDrainSpinLimit = 500; // 100 ms

// One complete ping-pong delay send and return, built once per tap length, so
// that the 1/8-note (R) and 1/16-note (T) echoes are the same machine at
// different clock divisions. The classic cross-fed ping-pong is a feedback
// cycle, which the engine graph this came from could not express; instead two
// acyclic lanes run at twice the tap period T, with the left lane offset by
// T, and they interleave into an exact alternating pattern. All delays are
// 100% wet, with per-hop decay f:
//
//   send -> half(T) -------------------> panLeft (-50%)   L: T
//           half -> left(2T,f^2) ------> panLeft          L: 3T, 5T ...
//   send -> right(2T,f^2) ------------> panRight(+50%, volume f)
//                                                         R: 2T, 4T ...
//   panLeft + panRight -> echoes -> lowCut -> out
//
// The pans and sums were mixers in the graph; here they are the arithmetic
// in VibeFXChainRender, and the two sends' identical low-cuts are one filter
// over their summed returns, which a linear filter cannot tell apart.
//
// The non-geometric decay is deliberate. The left lane's echoes at 3T, 5T and
// so on start at the lane's own first-tap level, because `left`'s first wet
// tap emerges at unity and panLeft cannot compensate: its first input carries
// the T tap, which must stay at unity. So every odd hop from 3 onwards lands
// f^2 hotter than a strict per-hop trail, about 1.8x at f=0.75, giving
// 1, f, 1, f^3, f^2, ... rather than 1, f, f^2, f^3, f^4. The result is a
// left-leaning surge on every second repeat rather than a smooth fade. It was
// auditioned and kept: it reads as bounce, not as a bug.

#pragma mark - The chain

// A stereo buffer list the render can build on its stack.
typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} VibeFXStereoList;

// One hosted unit and the scratch pair its input callback hands it.
typedef struct {
    AudioUnit _Nullable unit;
    float *source[2];
} VibeFXUnit;

// A send-return: its gate and its activity. The queue writes the target,
// the shadow and the generation and flips `active`; the audio thread slews
// `gain` toward the target and reads `active` before touching the stage.
typedef struct {
    _Atomic float target;
    _Atomic int32_t active;
    float gain;
    float shadow;        // the queue's last target, what the next ramp starts from
    uint64_t generation; // the ramp in flight; a newer toggle preempts by bumping it
    double tailSeconds;  // how long the stage renders after its gate closed
} VibeFXStage;

struct VibeFXChain {
    _Atomic int32_t connected;
    _Atomic int32_t inRender;   // 1 while the audio thread is inside the chain
    _Atomic int32_t eqActive;   // the low kill: on, sweeping, or settling after it parked
    _Atomic uint64_t unitRenders;
    double sampleRate;
    float slewPerFrame;
    UInt32 maxFrames;
    VibeFXStage reverbStage;
    VibeFXStage delayStage[2]; // 0: the 1/8-note send, 1: the 1/16-note send
    VibeFXUnit eq;
    VibeFXUnit reverb;
    VibeFXUnit reverbLowCut;
    VibeFXUnit delayLowCut;    // both sends' returns, summed first
    VibeFXUnit half[2];
    VibeFXUnit left[2];
    VibeFXUnit right[2];
    // Scratch, stereo, maxFrames each: the dry signal the EQ reads, a gated
    // send, a unit's output on its way to the next, the half-tap lane, a
    // lane in flight, and the delay returns summed before their one low-cut.
    float *dry[2];
    float *send[2];
    float *wet[2];
    float *halfTap[2];
    float *lane[2];
    float *echoes[2];
    float *storage;
};

#pragma mark - The audio thread

// The one call the compiler cannot check: AudioToolbox documents
// AudioUnitRender as the render thread's own entry point and attributes it
// with nothing. Everything around it is under the error pragma below.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
#endif
static inline OSStatus VibeFXRenderUnit(VibeFXChain *chain, VibeFXUnit *unit, const AudioTimeStamp *timestamp,
                                        UInt32 frames, float *const out[2]) CA_REALTIME_API {
    VibeFXStereoList list = { 2, { { 1, frames * (UInt32)sizeof(float), out[0] }, { 1, frames * (UInt32)sizeof(float), out[1] } } };
    AudioUnitRenderActionFlags flags = 0;
    atomic_fetch_add_explicit(&chain->unitRenders, 1, memory_order_relaxed);
    return AudioUnitRender(unit->unit, &flags, timestamp, 0, frames, (AudioBufferList *)&list);
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wfunction-effects"
#endif
static inline void VibeFXCopy(float *const to[2], float *const from[2], UInt32 frames) CA_REALTIME_API {
    memcpy(to[0], from[0], frames * sizeof(float));
    memcpy(to[1], from[1], frames * sizeof(float));
}

static inline void VibeFXAdd(float *const to[2], float *const from[2], UInt32 frames) CA_REALTIME_API {
    for (UInt32 f = 0; f < frames; f++) {
        to[0][f] += from[0][f];
        to[1][f] += from[1][f];
    }
}

// The mixer's balance law, measured: the far side attenuates linearly with
// the pan, the near side keeps its gain; `volume` is the mixer's own.
static inline void VibeFXPan(float *const io[2], UInt32 frames, float pan, float volume) CA_REALTIME_API {
    float left = volume * (pan > 0 ? 1.0f - pan : 1.0f);
    float right = volume * (pan < 0 ? 1.0f + pan : 1.0f);
    for (UInt32 f = 0; f < frames; f++) {
        io[0][f] *= left;
        io[1][f] *= right;
    }
}

// The gate: the gain moves toward the queue's target at the mixer's slew,
// evaluated per frame so a target written mid-block lands smoothly.
static inline void VibeFXGate(VibeFXStage *stage, float *const in[2], float *const out[2], UInt32 frames,
                              float slew) CA_REALTIME_API {
    float gain = stage->gain;
    float target = atomic_load_explicit(&stage->target, memory_order_relaxed);
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
    if (!chain || frames == 0 || frames > chain->maxFrames || io->mNumberBuffers < 2
            || !atomic_load_explicit(&chain->connected, memory_order_seq_cst)) {
        return noErr;
    }
    atomic_store_explicit(&chain->inRender, 1, memory_order_seq_cst);
    AudioTimeStamp stamp = {0};
    if (!timestamp) {
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        timestamp = &stamp;
    }
    float *out[2] = { io->mBuffers[0].mData, io->mBuffers[1].mData };
    OSStatus status = noErr;
    // The low kill, in place: the EQ reads a copy of the dry signal and
    // writes the output. Parked and settled it is skipped, and the dry path
    // is the bus sample for sample.
    if (atomic_load_explicit(&chain->eqActive, memory_order_seq_cst)) {
        VibeFXCopy(chain->dry, out, frames);
        status = VibeFXRenderUnit(chain, &chain->eq, timestamp, frames, out);
    }
    // The sends tap the post-low-kill signal. A stage renders while its gate
    // is open or its tail rings; the returns re-enter beside the dry path.
    if (atomic_load_explicit(&chain->reverbStage.active, memory_order_seq_cst)) {
        VibeFXGate(&chain->reverbStage, out, chain->send, frames, chain->slewPerFrame);
        VibeFXRenderUnit(chain, &chain->reverb, timestamp, frames, chain->wet);
        VibeFXRenderUnit(chain, &chain->reverbLowCut, timestamp, frames, chain->lane);
        VibeFXAdd(out, chain->lane, frames);
    }
    BOOL echoes = NO;
    for (int i = 0; i < 2; i++) {
        VibeFXStage *stage = &chain->delayStage[i];
        if (!atomic_load_explicit(&stage->active, memory_order_seq_cst)) {
            continue;
        }
        VibeFXGate(stage, out, chain->send, frames, chain->slewPerFrame);
        VibeFXRenderUnit(chain, &chain->half[i], timestamp, frames, chain->halfTap);
        // The right lane, panned right at one hop of decay: it first sounds at
        // 2T, a full hop after the left lane's T.
        VibeFXRenderUnit(chain, &chain->right[i], timestamp, frames, chain->lane);
        VibeFXPan(chain->lane, frames, kDelayPingPongPan, kDelayFeedbackPercent / 100.0f);
        if (echoes) {
            VibeFXAdd(chain->echoes, chain->lane, frames);
        }
        else {
            VibeFXCopy(chain->echoes, chain->lane, frames);
            echoes = YES;
        }
        // The left lane, fed by the half-tap lane, summed with it and panned left.
        VibeFXRenderUnit(chain, &chain->left[i], timestamp, frames, chain->lane);
        VibeFXAdd(chain->lane, chain->halfTap, frames);
        VibeFXPan(chain->lane, frames, -kDelayPingPongPan, 1.0f);
        VibeFXAdd(chain->echoes, chain->lane, frames);
    }
    if (echoes) {
        VibeFXRenderUnit(chain, &chain->delayLowCut, timestamp, frames, chain->lane);
        VibeFXAdd(out, chain->lane, frames);
    }
    atomic_store_explicit(&chain->inRender, 0, memory_order_release);
    return status;
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

#pragma mark - Hosting

// A unit's input: a copy of the scratch pair it was hosted over, into the
// buffer the unit allocated for itself. TRAP: a unit told not to allocate
// one (kAudioUnitProperty_ShouldAllocateBuffer = 0 on its input scope) is
// handed the scratch itself and writes its output back into it — AUDelay
// measured — so a lane reading that scratch after the unit reads the unit's
// output, and the delay's own tap never reaches the sum. Every unit keeps
// its input buffer.
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

// The unit's own reckoning of how long it keeps sounding after its input
// stopped, plus its latency.
static double VibeFXTailSeconds(AudioUnit unit) {
    Float64 tail = 0, latency = 0;
    UInt32 size = sizeof(Float64);
    AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
    size = sizeof(Float64);
    AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    return tail + latency;
}

static void VibeFXDispose(VibeFXUnit *unit) {
    if (unit->unit) {
        AudioUnitUninitialize(unit->unit);
        AudioComponentInstanceDispose(unit->unit);
        unit->unit = NULL;
    }
}

// Hosts one of Apple's units at `format` over `source`: formats on both
// scopes, the largest render, the input callback, `configure` before the
// initialize (for properties the unit takes only then), then the initialize.
static BOOL VibeFXHost(VibeFXUnit *unit, OSType type, OSType subtype, const AudioStreamBasicDescription *format,
                       UInt32 maxFrames, float *const source[2], void (^ _Nullable configure)(AudioUnit)) {
    VibeFXDispose(unit);
    unit->source[0] = source[0];
    unit->source[1] = source[1];
    AudioComponentDescription description = {
        .componentType = type, .componentSubType = subtype, .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit instance = NULL;
    if (!component || AudioComponentInstanceNew(component, &instance) != noErr || !instance) {
        LogError(@"AudioFX: no '%c%c%c%c' unit", (char)(subtype >> 24), (char)(subtype >> 16), (char)(subtype >> 8), (char)subtype);
        return NO;
    }
    unit->unit = instance;
    AudioStreamBasicDescription description2 = *format;
    UInt32 frames = maxFrames;
    AURenderCallbackStruct input = { .inputProc = VibeFXInput, .inputProcRefCon = unit };
    OSStatus status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &description2, sizeof(description2));
    if (status == noErr) {
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &description2, sizeof(description2));
    }
    if (status == noErr) {
        // TRAP: a directly hosted Apple unit defaults to 1156 frames per slice
        // and refuses the output unit's 4096-frame slices with
        // kAudioUnitErr_TooManyFramesToProcess; AVAudioEngine set this on
        // every node for us.
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
        VibeFXDispose(unit);
        return NO;
    }
    return YES;
}

// A one-band high-pass return filter, the tail and echo low-cuts.
static BOOL VibeFXHostLowCut(VibeFXUnit *unit, const AudioStreamBasicDescription *format, UInt32 maxFrames,
                             float *const source[2], float cutoffHz) {
    BOOL hosted = VibeFXHost(unit, kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ, format, maxFrames, source, ^(AudioUnit instance) {
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
    BOOL hosted = VibeFXHost(unit, kAudioUnitType_Effect, kAudioUnitSubType_Delay, format, maxFrames, source, nil);
    if (hosted) {
        VibeFXSetParameter(unit->unit, kDelayParam_WetDryMix, 100);
        VibeFXSetParameter(unit->unit, kDelayParam_Feedback, feedbackPercent);
        VibeFXSetParameter(unit->unit, kDelayParam_DelayTime, (float)seconds);
    }
    return hosted;
}

@implementation AudioFX {
    void (^_scheduler)(NSTimeInterval, dispatch_block_t);
    // The player's serial queue, shared rather than owned. All hosting and
    // parameter mutation runs here, as every other output touch in the app
    // does.
    dispatch_queue_t        _queue;
    // Guards the intent flags and delayTapBPM. The ramp generations are
    // queue-confined and need no lock.
    os_unfair_lock          _stateLock;
    VibeFXChain             *_chain;

    // Master-bus low-kill high-pass; the class comment gives its place in the
    // chain. _lowKillEnabled and _lowKillBoostActive are lock-guarded and hold
    // the UI-readable intent. The ramp generation is queue-confined and lets a
    // re-toggle mid-sweep preempt the old sweep; the frequency and the flat
    // flag shadow what the unit was last told, so a sweep starts where the
    // filter sits.
    BOOL                    _lowKillEnabled;
    BOOL                    _lowKillBoostActive;
    uint64_t                _lowKillRampGeneration;
    float                   _lowKillFrequency;
    BOOL                    _lowKillFlat;

    // The sends' intent, lock-guarded; their ramps and tails live in the
    // chain's stages, queue-confined. _delayTapBPM is the effective tempo
    // both delay sends follow.
    BOOL                    _reverbSendEnabled;
    BOOL                    _delaySendEnabled;
    BOOL                    _shortDelaySendEnabled;
    float                   _delayTapBPM;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(void (^)(NSTimeInterval, dispatch_block_t))scheduler {
    self = [super init];
    if (self) {
        _queue = queue;
        _scheduler = [scheduler copy];
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _chain = calloc(1, sizeof(VibeFXChain));
        if (!_chain) {
            return nil;
        }
        _lowKillFrequency = kLowKillParkedHz;
        _lowKillFlat = YES;
    }
    return self;
}

- (void)dealloc {
    [self disposeUnits];
    free(_chain->storage);
    free(_chain);
}

- (VibeFXChain *)chain {
    return _chain;
}

- (BOOL)connected {
    return atomic_load_explicit(&_chain->connected, memory_order_relaxed) != 0;
}

- (uint64_t)unitRenders {
    return atomic_load_explicit(&_chain->unitRenders, memory_order_relaxed);
}

- (NSUInteger)hostedUnitCount {
    VibeFXUnit *units[] = { &_chain->eq, &_chain->reverb, &_chain->reverbLowCut, &_chain->delayLowCut,
                            &_chain->half[0], &_chain->left[0], &_chain->right[0],
                            &_chain->half[1], &_chain->left[1], &_chain->right[1] };
    NSUInteger count = 0;
    for (size_t i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        count += units[i]->unit != NULL;
    }
    return count;
}

#pragma mark - Connecting

// Waits, briefly, for a render to leave the chain: the caller has just
// published a change the render reads before entering a stage, so once it is
// seen outside, no render can be inside what the caller resets or frees.
- (void)drainRenderOnQueue {
    for (int spin = 0; spin < kDrainSpinLimit && atomic_load_explicit(&_chain->inRender, memory_order_seq_cst); spin++) {
        usleep(kDrainSpinMicroseconds);
    }
}

- (void)setConnected:(BOOL)connected format:(nullable AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount {
    if (!connected) {
        [self disconnectOnQueue];
        return;
    }
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved && format.channelCount == 2);
    BOOL hosted = _chain->eq.unit != NULL;
    if (hosted && (_chain->sampleRate != format.sampleRate || _chain->maxFrames != maximumFrameCount)) {
        // Hosted at another rate: an effect cannot convert between its input
        // and output, so the units are hosted again at the new one, and the
        // recorded intent re-applied as at the first connect.
        [self disconnectOnQueue];
        [self disposeUnits];
        hosted = NO;
    }
    if (!hosted && ![self hostUnitsWithFormat:format maximumFrameCount:maximumFrameCount]) {
        [self disposeUnits];
        return;
    }
    if (self.connected) {
        return;
    }
    atomic_store_explicit(&_chain->connected, 1, memory_order_seq_cst);
    // Apply any intent recorded before the chain existed: a key or menu
    // action racing the async init, or the controller's first BPM feed.
    [self applyLowKillTargetOnQueue];
    [self applyDelayTapOnQueue];
    os_unfair_lock_lock(&_stateLock);
    BOOL reverbOn = _reverbSendEnabled;
    BOOL delayOn = _delaySendEnabled;
    BOOL shortDelayOn = _shortDelaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    if (reverbOn) {
        [self applySendGateOnQueue:&_chain->reverbStage enabled:YES level:kReverbSendLevel swellRatio:kReverbSwellRatio];
    }
    if (delayOn) {
        [self applySendGateOnQueue:&_chain->delayStage[0] enabled:YES level:kDelaySendLevel swellRatio:kDelaySwellRatio];
    }
    if (shortDelayOn) {
        [self applySendGateOnQueue:&_chain->delayStage[1] enabled:YES level:kDelaySendLevel swellRatio:kDelaySwellRatio];
    }
}

// The bypass: the chain leaves the render, and every tail and unfinished
// sweep is reset so the next connect starts clean.
- (void)disconnectOnQueue {
    atomic_store_explicit(&_chain->connected, 0, memory_order_seq_cst);
    [self drainRenderOnQueue];
    _lowKillRampGeneration++;
    atomic_store_explicit(&_chain->eqActive, 0, memory_order_seq_cst);
    VibeFXStage *stages[] = { &_chain->reverbStage, &_chain->delayStage[0], &_chain->delayStage[1] };
    for (size_t i = 0; i < 3; i++) {
        stages[i]->generation++;
        atomic_store_explicit(&stages[i]->active, 0, memory_order_seq_cst);
        atomic_store_explicit(&stages[i]->target, 0, memory_order_relaxed);
        stages[i]->shadow = 0;
        stages[i]->gain = 0;
    }
    if (_chain->eq.unit) {
        [self setLowKillBandsFlat:YES];
        [self setLowKillFrequency:kLowKillParkedHz];
    }
    [self resetUnits];
}

- (void)resetUnits {
    VibeFXUnit *units[] = { &_chain->eq, &_chain->reverb, &_chain->reverbLowCut, &_chain->delayLowCut,
                            &_chain->half[0], &_chain->left[0], &_chain->right[0],
                            &_chain->half[1], &_chain->left[1], &_chain->right[1] };
    for (size_t i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        if (units[i]->unit) {
            AudioUnitReset(units[i]->unit, kAudioUnitScope_Global, 0);
        }
    }
}

- (void)disposeUnits {
    VibeFXUnit *units[] = { &_chain->eq, &_chain->reverb, &_chain->reverbLowCut, &_chain->delayLowCut,
                            &_chain->half[0], &_chain->left[0], &_chain->right[0],
                            &_chain->half[1], &_chain->left[1], &_chain->right[1] };
    for (size_t i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        VibeFXDispose(units[i]);
    }
}

// Hosts every unit at `format` over the chain's scratch, parked: the low
// kill flat, the gates closed, no tempo yet (applyDelayTapOnQueue restates
// the times from the real one the moment the controller feeds it). The
// output is stopped, so no render is inside the chain.
- (BOOL)hostUnitsWithFormat:(AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount {
    VibeFXChain *chain = _chain;
    free(chain->storage);
    chain->storage = calloc((size_t)maximumFrameCount * 12, sizeof(float));
    if (!chain->storage) {
        return NO;
    }
    float **pairs[] = { chain->dry, chain->send, chain->wet, chain->halfTap, chain->lane, chain->echoes };
    for (size_t p = 0; p < 6; p++) {
        pairs[p][0] = chain->storage + (p * 2) * maximumFrameCount;
        pairs[p][1] = chain->storage + (p * 2 + 1) * maximumFrameCount;
    }
    chain->sampleRate = format.sampleRate;
    chain->maxFrames = maximumFrameCount;
    chain->slewPerFrame = (float)(1.0 / (kGateSlewSeconds * format.sampleRate));
    const AudioStreamBasicDescription *asbd = format.streamDescription;

    // The low kill: both bands stay live and un-bypassed for the chain's life
    // (see kLowKillParkedHz); the controls sweep the cutoff and swap the band
    // types through applyLowKillTargetOnQueue, and the parked state is the
    // transparent one — and, settled, the whole unit is skipped.
    BOOL hosted = VibeFXHost(&chain->eq, kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ, asbd, maximumFrameCount, chain->dry,
                             ^(AudioUnit instance) {
        UInt32 bands = 2;
        AudioUnitSetProperty(instance, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, sizeof(bands));
    });
    if (hosted) {
        _lowKillFlat = NO; // so the swap below writes the bands
        [self setLowKillBandsFlat:YES];
        [self setLowKillFrequency:kLowKillParkedHz];
        for (UInt32 band = 0; band < 2; band++) {
            VibeFXSetParameter(chain->eq.unit, kAUNBandEQParam_BypassBand + band, 0);
        }
    }

    // The reverb: MatrixReverb on macOS, whose raw kReverbParam_* knobs push
    // the Cathedral preset's tail out to the target length (see the
    // constants); Reverb2 elsewhere, plain. Fully wet: the dry signal only
    // ever travels the dry path, so opening the gate adds reverb on top.
#if TARGET_OS_OSX
    hosted = hosted && VibeFXHost(&chain->reverb, kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb, asbd, maximumFrameCount,
                                  chain->send, ^(AudioUnit instance) {
        AUPreset preset = { .presetNumber = kReverbCathedralPreset, .presetName = NULL };
        AudioUnitSetProperty(instance, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, sizeof(preset));
    });
    if (hosted) {
        VibeFXSetParameter(chain->reverb.unit, kReverbParam_DryWetMix, 100);
        VibeFXSetParameter(chain->reverb.unit, kReverbParam_SmallLargeMix, kReverbSmallLargeMix);
        VibeFXSetParameter(chain->reverb.unit, kReverbParam_LargeSize, kReverbLargeSize);
        VibeFXSetParameter(chain->reverb.unit, kReverbParam_LargeDensity, kReverbLargeDensity);
    }
#else
    hosted = hosted && VibeFXHost(&chain->reverb, kAudioUnitType_Effect, kAudioUnitSubType_Reverb2, asbd, maximumFrameCount,
                                  chain->send, nil);
    if (hosted) {
        VibeFXSetParameter(chain->reverb.unit, kReverb2Param_DryWetMix, 100);
    }
#endif
    hosted = hosted && VibeFXHostLowCut(&chain->reverbLowCut, asbd, maximumFrameCount, chain->wet, kReverbTailLowCutHz);
    hosted = hosted && VibeFXHostLowCut(&chain->delayLowCut, asbd, maximumFrameCount, chain->echoes, kDelayEchoLowCutHz);

    // Two ping-pong delay returns, the same machine at different clock
    // divisions; see the topology comment. Lane feedback is the per-hop decay
    // squared, because each lane repeats every two hops.
    float laneFeedbackPercent = VibeDelayLaneFeedbackPercent(kDelayFeedbackPercent);
    for (int i = 0; i < 2 && hosted; i++) {
        float beatsPerTap = i == 0 ? kDelayTapBeats : kShortDelayTapBeats;
        hosted = VibeFXHostDelay(&chain->half[i], asbd, maximumFrameCount, chain->send, 0, VibeDelayTapSeconds(0, beatsPerTap))
                && VibeFXHostDelay(&chain->left[i], asbd, maximumFrameCount, chain->halfTap, laneFeedbackPercent, VibeDelayLaneSeconds(0, beatsPerTap))
                && VibeFXHostDelay(&chain->right[i], asbd, maximumFrameCount, chain->send, laneFeedbackPercent, VibeDelayLaneSeconds(0, beatsPerTap));
    }
    if (!hosted) {
        return NO;
    }
    [self readTailsOnQueue];
    LogDebug(@"AudioFX: hosted %lu units at %.0f Hz", (unsigned long)self.hostedUnitCount, format.sampleRate);
    return YES;
}

// How long each stage keeps rendering after its gate closes: the longest of
// its units' own tail times plus the return filter's. Re-read whenever a
// delay time moves.
- (void)readTailsOnQueue {
    VibeFXChain *chain = _chain;
    if (!chain->reverb.unit) {
        return;
    }
    chain->reverbStage.tailSeconds = VibeFXTailSeconds(chain->reverb.unit) + VibeFXTailSeconds(chain->reverbLowCut.unit);
    for (int i = 0; i < 2; i++) {
        double tail = MAX(VibeFXTailSeconds(chain->half[i].unit),
                          MAX(VibeFXTailSeconds(chain->left[i].unit), VibeFXTailSeconds(chain->right[i].unit)));
        chain->delayStage[i].tailSeconds = tail + VibeFXTailSeconds(chain->delayLowCut.unit);
    }
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

// Runs on _queue. It resolves the single cutoff both controls share — the held
// boost, at double cutoff, outranks the Q toggle, which outranks parked — and
// sweeps there from wherever the filter currently sits. A re-toggle or release
// mid-sweep bumps the generation, preempting the old sweep, and starts from
// the current frequency, so there is no jump. Bypass is never touched after
// the host un-bypasses the bands once: flipping it dumps stale delay-line
// state into the signal, an audible click (see kLowKillParkedHz). "Off" is
// the cutoff swept down to the parked floor and then the bands swapped to
// their flat type, which is what makes it colorless — and once the residue
// has settled the unit is reset and skipped, which is what makes it free.
- (void)applyLowKillTargetOnQueue {
    // The guard is the UNIT: nothing is hosted until the first connect, which
    // re-applies this.
    if (!_chain->eq.unit || !self.connected) {
        return;
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
        atomic_store_explicit(&_chain->eqActive, 1, memory_order_seq_cst);
        [self setLowKillBandsFlat:NO];
    }
    [self stepLowKillRamp:1 from:_lowKillFrequency to:target generation:generation];
}

// The parked state is a 0 dB parametric band, an identity biquad — its
// feedback and feed-forward coefficients are equal, so it passes the signal
// bit-exact — rather than a high-pass at the frequency floor, which at 20 Hz
// still lifted the sub-bass by up to 4 dB through the resonant band's peak.
// Swapping the type changes coefficients under the retained filter state, so
// the old response's residue decays at the band's own 20 Hz with no
// discontinuity — unlike bypass, which clicks. Idempotent: a repeated swap to
// the same type would restart that decay for nothing.
- (void)setLowKillBandsFlat:(BOOL)flat {
    if (flat == _lowKillFlat) {
        return;
    }
    _lowKillFlat = flat;
    AudioUnit unit = _chain->eq.unit;
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
    for (UInt32 band = 0; band < 2; band++) {
        VibeFXSetParameter(_chain->eq.unit, kAUNBandEQParam_Frequency + band, frequency);
    }
}

// The fade-loop pattern applied to the filter cutoff, stepped along a
// log-frequency curve — multiplicative interpolation, as in the volume fades
// — at the finer low-kill cadence. A sweep that lands at the floor goes
// colorless, and once the swap's residue has settled the unit rests.
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
                    [strongSelf restLowKillOnQueue];
                }
            });
        }
        return;
    }
    _scheduler(kLowKillSweepStepMicroseconds / 1000000.0, ^{
        [weakSelf stepLowKillRamp:step + 1 from:start to:target generation:generation];
    });
}

// The parked EQ leaves the render and forgets its state, so the next engage
// starts from an exact identity.
- (void)restLowKillOnQueue {
    if (!atomic_load_explicit(&_chain->eqActive, memory_order_relaxed)) {
        return;
    }
    atomic_store_explicit(&_chain->eqActive, 0, memory_order_seq_cst);
    [self drainRenderOnQueue];
    AudioUnitReset(_chain->eq.unit, kAudioUnitScope_Global, 0);
}

#pragma mark - The sends

- (BOOL)reverbSendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _reverbSendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setReverbSendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_reverbSendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _reverbSendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applySendGateOnQueue:&self->_chain->reverbStage enabled:enabled
                             level:kReverbSendLevel swellRatio:kReverbSwellRatio];
    });
}

- (BOOL)delaySendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _delaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setDelaySendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_delaySendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _delaySendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applySendGateOnQueue:&self->_chain->delayStage[0] enabled:enabled
                             level:kDelaySendLevel swellRatio:kDelaySwellRatio];
    });
}

- (BOOL)shortDelaySendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _shortDelaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setShortDelaySendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_shortDelaySendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _shortDelaySendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applySendGateOnQueue:&self->_chain->delayStage[1] enabled:enabled
                             level:kDelaySendLevel swellRatio:kDelaySwellRatio];
    });
}

// Runs on _queue. Opens or closes a send gate. Opening is a fast fade on the
// volume-fade cadence — an instant volume step clicks, whereas
// kFadeDurationMilliseconds does not — followed, while the gate stays open, by
// a slow swell up to swellRatio times the base level. Closing cuts only the
// send: the stage keeps rendering for its tail, which decays naturally, and
// only then rests. A re-toggle mid-ramp preempts through the generation and
// continues from the current gate level.
- (void)applySendGateOnQueue:(VibeFXStage *)stage enabled:(BOOL)enabled level:(float)level swellRatio:(float)swellRatio {
    if (!_chain->reverb.unit || !self.connected) {
        return; // Not hosted yet. The first connect re-applies it.
    }
    uint64_t generation = ++stage->generation;
    if (!enabled) {
        [self stepSendGateRamp:stage step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                          from:stage->shadow to:0 generation:generation completion:nil];
        return;
    }
    // A resting stage joins the render before its gate opens; reset, it
    // starts from silence under the gate's fade-in.
    atomic_store_explicit(&stage->active, 1, memory_order_seq_cst);
    __weak AudioFX *weakSelf = self;
    [self stepSendGateRamp:stage step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                      from:stage->shadow to:level generation:generation completion:^{
        // The same generation is used, so the release or re-press that would
        // invalidate the swell bumps the generation and the first swell step
        // drops out.
        [weakSelf stepSendGateRamp:stage step:1 of:kSendSwellSteps stepMicroseconds:kSendSwellStepMicroseconds
                              from:level to:VibeSendSwellLevel(level, swellRatio)
                        generation:generation completion:nil];
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
        [self setStage:stage target:target];
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
    [self setStage:stage target:VibeFadeVolumeOverSteps(start, target, step, steps)];
    _scheduler(stepMicroseconds / 1000000.0, ^{
        [weakSelf stepSendGateRamp:stage step:step + 1 of:steps stepMicroseconds:stepMicroseconds from:start to:target generation:generation completion:completion];
    });
}

- (void)setStage:(VibeFXStage *)stage target:(float)target {
    stage->shadow = target;
    atomic_store_explicit(&stage->target, target, memory_order_relaxed);
}

// The stage leaves the render and forgets its tail, so the next engage
// starts from silence. The delays' shared low-cut rests with the last of them.
- (void)restStageOnQueue:(VibeFXStage *)stage {
    if (!atomic_load_explicit(&stage->active, memory_order_relaxed)) {
        return;
    }
    atomic_store_explicit(&stage->active, 0, memory_order_seq_cst);
    [self drainRenderOnQueue];
    stage->gain = 0;
    VibeFXChain *chain = _chain;
    if (stage == &chain->reverbStage) {
        AudioUnitReset(chain->reverb.unit, kAudioUnitScope_Global, 0);
        AudioUnitReset(chain->reverbLowCut.unit, kAudioUnitScope_Global, 0);
        return;
    }
    int i = stage == &chain->delayStage[0] ? 0 : 1;
    AudioUnitReset(chain->half[i].unit, kAudioUnitScope_Global, 0);
    AudioUnitReset(chain->left[i].unit, kAudioUnitScope_Global, 0);
    AudioUnitReset(chain->right[i].unit, kAudioUnitScope_Global, 0);
    if (!atomic_load_explicit(&chain->delayStage[1 - i].active, memory_order_relaxed)) {
        AudioUnitReset(chain->delayLowCut.unit, kAudioUnitScope_Global, 0);
    }
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

// Runs on _queue. The delays sit post-varispeed, so tap time is wall-clock and
// matches the effective, pitch-scaled tempo the controller provides. Each
// send's lanes run at twice its tap; see the topology comment. AUDelay caps
// its delay time at two seconds, so the 1/8-note send's lanes pin there below
// an effective 30 BPM, well beyond any real tempo.
- (void)applyDelayTapOnQueue {
    if (!_chain->half[0].unit) {
        return; // Not hosted yet. The first connect re-applies it.
    }
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    for (int i = 0; i < 2; i++) {
        float beatsPerTap = i == 0 ? kDelayTapBeats : kShortDelayTapBeats;
        float lane = (float)VibeDelayLaneSeconds(bpm, beatsPerTap);
        VibeFXSetParameter(_chain->half[i].unit, kDelayParam_DelayTime, (float)VibeDelayTapSeconds(bpm, beatsPerTap));
        VibeFXSetParameter(_chain->left[i].unit, kDelayParam_DelayTime, lane);
        VibeFXSetParameter(_chain->right[i].unit, kDelayParam_DelayTime, lane);
    }
    [self readTailsOnQueue];
}

@end
