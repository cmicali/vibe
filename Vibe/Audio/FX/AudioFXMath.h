//
//  AudioFXMath.h
//  Vibe
//
//  The numbers AudioFX's toggles resolve to, as static inlines so the unit
//  tests reach them without a render pipeline. The graph they are applied to —
//  the low-kill EQ, the gated send-returns, the ping-pong delay lanes — lives
//  in AudioFX.m, which is where every unit-hosting trap is recorded.
//
//  Only the arithmetic is here. The on/off intent, its lock, the ramp
//  generations and the sweep loops stay with the class: they are about
//  ordering and preemption, which a pure function cannot express.
//

#import <Foundation/Foundation.h>
#import "HelperMacros.h" // clampRange

// Low-kill high-pass cutoff while engaged: bass and kick gone, mids untouched.
static const float kLowKillCutoffHz = 200.0f;
// A held W drives the same filter to double the toggle's cutoff, 400 Hz: a
// momentary harder kill that releases back to the Q state.
static const float kLowKillBoostMultiplier = 2.0f;
// The parked, disengaged cutoff: AUNBandEQ's frequency floor. A high-pass
// parked here is not colorless — the resonant band's peak lifts 20–60 Hz by
// up to 4 dB — so once the sweep lands here AudioFX swaps the bands to a 0 dB
// parametric type, an identity filter, and swaps back before sweeping up. The
// bands are never bypassed, because flipping bypass dumps stale delay-line
// state into the signal and clicks audibly; a type swap keeps the state and
// only lets the old response decay out at this frequency.
static const float kLowKillParkedHz = 20.0f;

// The tap length with no tempo known: 0.25s at the 1/8-note division.
static const float kDelayDefaultBPM = 120.0f;

// The iOS pad's ceilings. Its Y axis sweeps the low kill's cutoff from
// parked up to here, log-frequency so each equal move is the same musical
// interval; the mac's momentary boost sits a third of the way up it. Its X
// axis is the reverb send across the whole axis, and past the onset the
// 1/8-note delay blends in on top of it, so the far right is both at full.
static const float kFXPadLowCutMaxHz = 1200.0f;
static const float kFXPadDelayOnset = 0.5f;

// The single cutoff the two low-kill controls share. The held boost outranks
// the Q toggle, which outranks parked — and the boost runs the filter even
// while the toggle reads off, which is what makes it a three-way resolution
// rather than two independent flags. (AudioFX coupling: clearing the toggle
// also clears the boost, so the middle case cannot outlive its filter.)
static inline float VibeLowKillCutoffHz(BOOL enabled, BOOL boostActive) {
    if (boostActive) {
        return kLowKillCutoffHz * kLowKillBoostMultiplier;
    }
    return enabled ? kLowKillCutoffHz : kLowKillParkedHz;
}

// The pad's vertical position, 0 at the bottom edge and 1 at the top, as
// the low kill's cutoff. At or below the bottom the filter is parked — the
// same colorless off the mac's toggle sweeps to — and above it the cutoff
// climbs the log curve to the ceiling, clamped there past the top. Never
// zero or negative: the sweep interpolates multiplicatively.
static inline float VibeFXPadLowCutHz(float y) {
    if (!(y > 0)) {
        return kLowKillParkedHz;
    }
    return kLowKillParkedHz * powf(kFXPadLowCutMaxHz / kLowKillParkedHz, clampRange(y, 0.0f, 1.0f));
}

// The pad's horizontal position, 0 at the left edge and 1 at the right, as
// the reverb send's level: 0 to 1 across the whole axis, where 1 is the level
// a held key swells to. Clamped at both ends.
static inline float VibeFXPadReverbLevel(float x) {
    return clampRange(x, 0.0f, 1.0f);
}

// The same position as the 1/8-note delay send's level: nothing up to the
// onset, then 0 to 1 over the rest of the axis, so the echo arrives once the
// reverb is already half up.
static inline float VibeFXPadDelayLevel(float x) {
    return clampRange((x - kFXPadDelayOnset) / (1 - kFXPadDelayOnset), 0.0f, 1.0f);
}

// Seconds per tap at the effective, pitch-scaled tempo. The delays sit
// post-varispeed, so tap time is wall-clock. A tempo of zero or less means no
// tempo is known — the label shows nothing — and the default stands in rather
// than dividing by zero.
static inline NSTimeInterval VibeDelayTapSeconds(float bpm, float beatsPerTap) {
    float effectiveBPM = bpm > 0 ? bpm : kDelayDefaultBPM;
    return 60.0 / (NSTimeInterval)effectiveBPM * (NSTimeInterval)beatsPerTap;
}

// Each ping-pong lane repeats every SECOND hop — the two lanes interleave at
// twice the tap period, offset by one tap — so a lane's delay time is twice
// the tap. See VibeDelaySend's topology comment.
static inline NSTimeInterval VibeDelayLaneSeconds(float bpm, float beatsPerTap) {
    return VibeDelayTapSeconds(bpm, beatsPerTap) * 2;
}

// And for the same reason a lane's own feedback is the per-hop decay squared:
// one lane revolution is two hops.
static inline float VibeDelayLaneFeedbackPercent(float hopFeedbackPercent) {
    float hopDecay = hopFeedbackPercent / 100.0f;
    return hopDecay * hopDecay * 100.0f;
}

// Where a held send gate swells to. After the fast open it keeps rising gently
// for as long as the key is held, so the effect builds the longer it is
// ridden, like easing a send fader up.
static inline float VibeSendSwellLevel(float level, float swellRatio) {
    return level * swellRatio;
}
