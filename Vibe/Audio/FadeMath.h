//
//  FadeMath.h
//  Vibe
//
//  Every fade exists for one reason: a gain step at a non-zero sample clicks.
//  Two curves, split by fade length. The declick — the ≤10 ms edge every
//  transport action rides — is linear in amplitude, which is inaudible at that
//  length and keeps the per-sample step small enough at every rate. A
//  crossfade-length fade is equal-power, so the two sides of a track change
//  sum to ~constant power instead of dipping at the midpoint.
//
//  The voice bus evaluates the curves per frame on the audio thread
//  (VibeFadeGainAtFrame). AudioFX's send gates step them on the player queue
//  and keep the older multiplicative (log) curve, which sounds right for a
//  gate opening onto a wet return.
//

#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioBaseTypes.h>
#import <math.h>

// The declick length, and the tunable that matters: long enough that no
// transport edge clicks, short enough to feel instant.
static const uint64_t kFadeDurationMilliseconds = 10;

typedef NS_ENUM(int32_t, VibeFadeCurve) {
    VibeFadeCurveLinear = 0,
    VibeFadeCurveEqualPower = 1,
};

// Declick-length fades are linear; every longer fade is one side of a crossfade.
static inline VibeFadeCurve VibeFadeCurveForMilliseconds(uint64_t milliseconds) {
    return milliseconds <= kFadeDurationMilliseconds ? VibeFadeCurveLinear : VibeFadeCurveEqualPower;
}

static inline uint32_t VibeFadeFramesForMilliseconds(uint64_t milliseconds, double sampleRate) {
    return (uint32_t)llround((double)milliseconds * sampleRate / 1000.0);
}

// The gain at `frame` of a from-to fade over `frames`. Computed from the
// frame index rather than accumulated, so the ramp lands on `to` exactly and
// a landed voice mixes at precisely its target. Audio-thread safe: pure math.
static inline float VibeFadeGainAtFrame(VibeFadeCurve curve, float from, float to,
                                        uint32_t frame, uint32_t frames) CA_REALTIME_API {
    if (frames == 0 || frame >= frames) {
        return to;
    }
    float t = (float)frame / (float)frames;
    if (curve == VibeFadeCurveEqualPower) {
        float power = from * from * (1.0f - t) + to * to * t;
        return sqrtf(power > 0.0f ? power : 0.0f);
    }
    return from + (to - from) * t;
}

// The length BOTH sides of a track change ride — the outgoing voice's retire
// and the incoming voice's fade-in — which is why it is one rule rather than
// two tests at two call sites. The user's crossfade applies to exactly one
// case, a play replacing an *audibly playing* track; everything else takes
// the declick minimum so transport stays instant:
//
//   replacingAudibleTrack  a first play, or one from pause or stop, has no
//                          outgoing audio to fade against
//   declick                the convert swap replaces a track with its OWN
//                          audio, which a crossfade would only dip
//
// The floor matters as much as the ceiling: a setting below the declick
// minimum would fade faster than the minimum that exists to stop the click.
static inline uint64_t VibeIncomingFadeMilliseconds(NSInteger crossfadeMilliseconds,
                                                    BOOL replacingAudibleTrack,
                                                    BOOL declick) {
    if (!replacingAudibleTrack || declick) {
        return kFadeDurationMilliseconds;
    }
    return (uint64_t)MAX(crossfadeMilliseconds, (NSInteger)kFadeDurationMilliseconds);
}

// Whether the crossfade setting permits arming a gapless splice: only at the
// declick minimum, which the UI presents as crossfade off. A longer setting
// asks for overlapped transitions, and auto-advance then crossfades instead.
static inline BOOL VibeGaplessArmAllowed(NSInteger crossfadeMilliseconds) {
    return crossfadeMilliseconds <= (NSInteger)kFadeDurationMilliseconds;
}

#pragma mark - Stepped fades (AudioFX's send gates)

static const int kFadeSteps = 10;
static const uint64_t kFadeStepMicroseconds = kFadeDurationMilliseconds * 1000 / kFadeSteps;
static const float kFadeFloor = 0.001f; // -60 dB

// Log curve: the volume at `step` of a from-to fade over `totalSteps`, in
// equal multiplicative steps. It lands exactly on `to` at the final step, and
// the floor keeps the log interpolation defined through silence.
static inline float VibeFadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)totalSteps);
}

#pragma mark - Retired with AVAudioPlayerNode; deleted by the voice-bus cutover

static inline float VibeCrossfadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float t = (float)step / (float)totalSteps;
    return sqrtf(from * from * (1.0f - t) + to * to * t);
}

static inline float VibeFadeVolumeForFadeLength(uint64_t milliseconds, float from, float to, int step, int totalSteps) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return VibeFadeVolumeOverSteps(from, to, step, totalSteps);
    }
    return VibeCrossfadeVolumeOverSteps(from, to, step, totalSteps);
}

static inline int VibeFadeStepsForMilliseconds(uint64_t milliseconds) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return kFadeSteps;
    }
    return (int)((milliseconds + 9) / 10);
}

static inline uint64_t VibeFadeStepMicrosecondsForMilliseconds(uint64_t milliseconds) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return kFadeStepMicroseconds;
    }
    return milliseconds * 1000 / (uint64_t)VibeFadeStepsForMilliseconds(milliseconds);
}

static inline uint64_t VibeIncomingFadeMillisecondsWithQueuedSegment(NSInteger crossfadeMilliseconds,
                                                                     BOOL replacingAudibleTrack,
                                                                     BOOL declick,
                                                                     BOOL segmentQueued) {
    if (segmentQueued) {
        return kFadeDurationMilliseconds;
    }
    return VibeIncomingFadeMilliseconds(crossfadeMilliseconds, replacingAudibleTrack, declick);
}
