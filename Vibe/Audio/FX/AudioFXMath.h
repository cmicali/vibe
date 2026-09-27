//
//  AudioFXMath.h
//  Vibe
//
//  The numbers AudioFX's toggles resolve to, tested without a pipeline.
//

#import <Foundation/Foundation.h>
#import "HelperMacros.h" // clampRange

// Low-kill high-pass cutoff while engaged: bass and kick gone, mids untouched.
static const float kLowKillCutoffHz = 200.0f;
// A held W: double the toggle's cutoff.
static const float kLowKillBoostMultiplier = 2.0f;
// AUNBandEQ's frequency floor. A high-pass parked here still lifts 20–60 Hz
// by up to 4 dB, so AudioFX swaps the bands to a 0 dB parametric type here.
// Never bypass them: flipping bypass dumps stale filter state and clicks,
// while a type swap keeps the state.
static const float kLowKillParkedHz = 20.0f;

// The tap length with no tempo known: 0.25s at the 1/8-note division.
static const float kDelayDefaultBPM = 120.0f;

// The iOS pad's ceilings: Y sweeps the cutoff from parked to here on a log
// curve (the mac's boost sits a third of the way up); X is the reverb across
// the axis, with the 1/8-note delay blending in past the onset.
static const float kFXPadLowCutMaxHz = 1200.0f;
static const float kFXPadDelayOnset = 0.5f;

// The boost outranks the toggle, which outranks parked; the boost runs the
// filter even while the toggle reads off.
static inline float VibeLowKillCutoffHz(BOOL enabled, BOOL boostActive) {
    if (boostActive) {
        return kLowKillCutoffHz * kLowKillBoostMultiplier;
    }
    return enabled ? kLowKillCutoffHz : kLowKillParkedHz;
}

// The pad's vertical position, 0 bottom to 1 top, as the cutoff: at or below
// the bottom parked (the colorless off), above it the log curve to the
// ceiling. Never zero: the sweep interpolates multiplicatively.
static inline float VibeFXPadLowCutHz(float y) {
    if (!(y > 0)) {
        return kLowKillParkedHz;
    }
    return kLowKillParkedHz * powf(kFXPadLowCutMaxHz / kLowKillParkedHz, clampRange(y, 0.0f, 1.0f));
}

// The pad's horizontal position, 0 left to 1 right, as the reverb level.
static inline float VibeFXPadReverbLevel(float x) {
    return clampRange(x, 0.0f, 1.0f);
}

// The same position as the 1/8-note delay's level: nothing to the onset,
// then 0..1 over the rest.
static inline float VibeFXPadDelayLevel(float x) {
    return clampRange((x - kFXPadDelayOnset) / (1 - kFXPadDelayOnset), 0.0f, 1.0f);
}

// Wall-clock seconds per tap (the delays sit post-varispeed); no tempo takes
// the default.
static inline NSTimeInterval VibeDelayTapSeconds(float bpm, float beatsPerTap) {
    float effectiveBPM = bpm > 0 ? bpm : kDelayDefaultBPM;
    return 60.0 / (NSTimeInterval)effectiveBPM * (NSTimeInterval)beatsPerTap;
}

// Each ping-pong lane repeats every second hop, so its delay is twice the tap
// (the topology comment in AudioFX.m).
static inline NSTimeInterval VibeDelayLaneSeconds(float bpm, float beatsPerTap) {
    return VibeDelayTapSeconds(bpm, beatsPerTap) * 2;
}

// Likewise a lane's feedback is the per-hop decay squared.
static inline float VibeDelayLaneFeedbackPercent(float hopFeedbackPercent) {
    float hopDecay = hopFeedbackPercent / 100.0f;
    return hopDecay * hopDecay * 100.0f;
}

// Where a held send gate swells to.
static inline float VibeSendSwellLevel(float level, float swellRatio) {
    return level * swellRatio;
}
