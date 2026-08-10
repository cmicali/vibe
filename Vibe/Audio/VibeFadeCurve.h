//
//  VibeFadeCurve.h
//  Vibe
//
//  The fade curves and cadence shared by AudioPlayer's node fades and
//  AudioFX's send gates. Two curves, split by fade length: declick-length
//  fades (kFadeDurationMilliseconds) step multiplicatively — perceptually
//  logarithmic, click-free down to the -60 dB floor — while crossfade-length
//  fades interpolate power linearly, so the two sides of a crossfade sum to
//  ~constant power instead of both sitting near -30 dB at the midpoint.
//  AudioFX's send gates are gates, not crossfades, and always ride the log
//  curve. Each caller keeps its own stepper loop, because the preemption
//  bookkeeping differs, but a change to a curve or the cadence here lands
//  everywhere.
//

#import <Foundation/Foundation.h>
#import <math.h>

static const int kFadeSteps = 10;
// The total ramp duration, and the tunable that matters. It is long enough
// that no fade-driven transition — pause, seek, skip or crossfade — clicks,
// and short enough to feel instant.
static const uint64_t kFadeDurationMilliseconds = 10;
// The step delay in microseconds, derived from the total and fed to
// dispatch_after through NSEC_PER_USEC.
static const uint64_t kFadeStepMicroseconds = kFadeDurationMilliseconds * 1000 / kFadeSteps;
static const float kFadeFloor = 0.001f; // -60 dB

// Declick (log) curve: the volume at `step` of a from-to fade over
// `totalSteps`, in equal multiplicative steps. It lands exactly on `to` at
// the final step, and the floor keeps the log interpolation defined through
// silence.
static inline float VibeFadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)totalSteps);
}

// Crossfade (equal-power) curve: power, volume squared, interpolates
// linearly, so a fade-out and a fade-in over the same steps are complementary
// and their power sum stays ~1. It lands exactly on `to` at the final step.
static inline float VibeCrossfadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float t = (float)step / (float)totalSteps;
    return sqrtf(from * from * (1.0f - t) + to * to * t);
}

// Curve selection by fade length: the log curve at the declick length —
// pause, seek, stop and transport declicks — and equal power beyond it, since
// every longer fade is one side of a crossfade.
static inline float VibeFadeVolumeForFadeLength(uint64_t milliseconds, float from, float to, int step, int totalSteps) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return VibeFadeVolumeOverSteps(from, to, step, totalSteps);
    }
    return VibeCrossfadeVolumeOverSteps(from, to, step, totalSteps);
}

// Step count for a fade of `milliseconds` total: the default cadence at the
// declick length, ~10ms per step beyond it, so a long crossfade ramps in
// small volume increments instead of ten audible stair-steps.
static inline int VibeFadeStepsForMilliseconds(uint64_t milliseconds) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return kFadeSteps;
    }
    // Round up: truncation gave 11-19ms a single step, and a 1-step ramp
    // snaps straight to the target — the click a fade exists to avoid.
    return (int)((milliseconds + 9) / 10);
}

static inline uint64_t VibeFadeStepMicrosecondsForMilliseconds(uint64_t milliseconds) {
    if (milliseconds <= kFadeDurationMilliseconds) {
        return kFadeStepMicroseconds;
    }
    return milliseconds * 1000 / (uint64_t)VibeFadeStepsForMilliseconds(milliseconds);
}
