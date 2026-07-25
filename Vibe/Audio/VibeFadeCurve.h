//
//  VibeFadeCurve.h
//  Vibe
//
//  The one fade curve: kFadeDurationMilliseconds total, in kFadeSteps equal
//  multiplicative (perceptually log) volume steps, shared by AudioPlayer's
//  node fades and AudioFX's send gates. Each keeps its own stepper loop (the
//  preemption bookkeeping differs); curve and cadence changes here land
//  everywhere.
//

#import <Foundation/Foundation.h>
#import <math.h>

static const int kFadeSteps = 10;
// Total ramp duration — THE tunable. Long enough that no fade-driven
// transition (pause, seek, skip, crossfade) clicks; short enough to feel
// instant.
static const uint64_t kFadeDurationMilliseconds = 10;
// Step delay in microseconds, derived from the total; fed to dispatch_after
// via NSEC_PER_USEC.
static const uint64_t kFadeStepMicroseconds = kFadeDurationMilliseconds * 1000 / kFadeSteps;
static const float kFadeFloor = 0.001f; // -60 dB

// Volume at `step` of a from->to fade; lands exactly on `to` at the final
// step. The floor keeps the log interpolation defined through silence.
static inline float VibeFadeVolume(float from, float to, int step) {
    if (step >= kFadeSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)kFadeSteps);
}
