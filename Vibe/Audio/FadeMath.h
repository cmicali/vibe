//
//  FadeMath.h
//  Vibe
//
//  Every fade exists because a gain step at a non-zero sample clicks. The
//  ≤10 ms declick is linear, which keeps its per-sample step small at every
//  rate; a longer fade is equal-power, so the two sides of a crossfade do not
//  dip at the midpoint. The voice bus evaluates both per frame on the audio
//  thread; AudioFX's send gates step a log curve on the player queue instead.
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

// Computed from the frame index, not accumulated, so the ramp lands on `to`
// exactly.
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

// The length both sides of a track change ride. The user's crossfade applies
// only to a play replacing an audibly playing track, without `declick` (the
// convert swap replaces a track with its own audio, which a crossfade would
// only dip); everything else takes the declick minimum, which is also the
// floor.
static inline uint64_t VibeIncomingFadeMilliseconds(NSInteger crossfadeMilliseconds,
                                                    BOOL replacingAudibleTrack,
                                                    BOOL declick) {
    if (!replacingAudibleTrack || declick) {
        return kFadeDurationMilliseconds;
    }
    return (uint64_t)MAX(crossfadeMilliseconds, (NSInteger)kFadeDurationMilliseconds);
}

// Gapless arms only at the declick minimum, which the UI presents as
// crossfade off; a longer setting crossfades auto-advance instead
// (VibeTrackEndCrossfadeMilliseconds) — except
// into the next window of the same file (AudioTrack
// isFollowedContiguouslyBy:), one recording a crossfade would overlap with
// itself.
static inline BOOL VibeGaplessArmAllowed(NSInteger crossfadeMilliseconds, BOOL continuesTheRecording) {
    return continuesTheRecording || crossfadeMilliseconds <= (NSInteger)kFadeDurationMilliseconds;
}

// The crossfade into the parked successor at a track's end: 0 while it is not
// due, else its length. The setting is held to half the track, so a short one
// is still heard, and to what remains, so the outgoing side lands on silence
// before its file ends. Due `lateness` early, the most the drain that notices
// can be late; the outgoing side then reaches silence that much before its
// end. A fade no longer than the declick is no crossfade: the track ends.
static inline uint64_t VibeTrackEndCrossfadeMilliseconds(NSInteger crossfadeMilliseconds, NSTimeInterval remaining,
                                                         NSTimeInterval duration, NSTimeInterval lateness) {
    double fade = MIN((double)crossfadeMilliseconds / 1000.0, duration / 2);
    if (remaining > fade + lateness) {
        return 0;
    }
    uint64_t milliseconds = (uint64_t)llround(MAX(0, MIN(fade, remaining)) * 1000);
    return milliseconds > kFadeDurationMilliseconds ? milliseconds : 0;
}

#pragma mark - Stepped fades (AudioFX's send gates)

static const int kFadeSteps = 10;
static const uint64_t kFadeStepMicroseconds = kFadeDurationMilliseconds * 1000 / kFadeSteps;
static const float kFadeFloor = 0.001f; // -60 dB

// Equal multiplicative steps, landing exactly on `to`; the floor keeps the
// log interpolation defined through silence.
static inline float VibeFadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)totalSteps);
}
