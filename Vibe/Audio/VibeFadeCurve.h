//
//  VibeFadeCurve.h
//  Vibe
//
//  The one fade curve: kFadeDurationMilliseconds in total, across kFadeSteps
//  equal multiplicative, perceptually logarithmic volume steps, shared by
//  AudioPlayer's node fades and AudioFX's send gates. Each keeps its own
//  stepper loop, because the preemption bookkeeping differs, but a change to
//  the curve or cadence here lands everywhere.
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

// The volume at `step` of a from-to fade. It lands exactly on `to` at the
// final step, and the floor keeps the log interpolation defined through
// silence.
static inline float VibeFadeVolume(float from, float to, int step) {
    if (step >= kFadeSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)kFadeSteps);
}
