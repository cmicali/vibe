//
//  AudioFXMath.h
//  Vibe
//
//  The numbers AudioFX's toggles resolve to, as static inlines so the unit
//  tests reach them without an AVAudioEngine. The graph they are applied to —
//  the low-kill EQ, the gated send-returns, the ping-pong delay lanes — lives
//  in AudioFX.m, which is where every AVFAudio trap is recorded.
//
//  Only the arithmetic is here. The on/off intent, its lock, the ramp
//  generations and the sweep loops stay with the class: they are about
//  ordering and preemption, which a pure function cannot express.
//

#import <Foundation/Foundation.h>

// Low-kill high-pass cutoff while engaged: bass and kick gone, mids untouched.
static const float kLowKillCutoffHz = 200.0f;
// A held W drives the same filter to double the toggle's cutoff, 400 Hz: a
// momentary harder kill that releases back to the Q state.
static const float kLowKillBoostMultiplier = 2.0f;
// The parked, disengaged cutoff: AUNBandEQ's frequency floor, below the
// audible band, so the filter is inaudible while parked. The bands are never
// bypassed, because un-bypassing one dumps its stale delay-line state into the
// signal and clicks audibly. On and off are purely a cutoff sweep between
// these two values.
static const float kLowKillParkedHz = 20.0f;

// The tap length with no tempo known: 0.25s at the 1/8-note division.
static const float kDelayDefaultBPM = 120.0f;

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
