//
//  WaveformLevelMath.h
//  Vibe
//
//  The chunk-to-level mapping every bar style draws from, and the one gain
//  setting that bends it, and the bar-count rules around it. Header-only and
//  Foundation-only, so the mapping is testable without the renderer headers'
//  C++ and Core Animation imports.
//

#import <Foundation/Foundation.h>
#import <math.h>
#import "HelperMacros.h"

// Energy, not peaks: on a limited master every coarse bar holds a full-scale
// transient and the strip reads as a block, while RMS still varies through
// drops and breakdowns. Full height is -9 dBFS RMS, a loud club master's
// sustained level; hotter clamps.
static const float kVibeWaveformFullScaleRMS = 0.35f;

// Gain is a display gain ahead of the clamp and also a curve bend: the
// exponent doubles per this many dB down (expanding a pegged master's
// variation) and halves per as many up (compressing, as a limiter reads).
static const float kVibeWaveformGainDBPerExponentDoubling = 24.0f;

// fullScaleRMS draws full height at 0 dB: the fixed reference, or under
// Normalize the track's loudest column capped at it, so normalizing only
// raises.
static inline float VibeWaveformBarLevel(float meanSquare, float fullScaleRMS, float gainDB) {
    float level = sqrtf(fmaxf(meanSquare, 0.0f)) / fullScaleRMS;
    if (gainDB == 0) {
        return fminf(level, 1.0f);
    }
    float gain = powf(10.0f, gainDB / 20.0f);
    float exponent = exp2f(-gainDB / kVibeWaveformGainDBPerExponentDoubling);
    return fminf(powf(level * gain, exponent), 1.0f);
}

// A bar's level averages energy over a column no finer than 1/1024 of the
// track (~0.4s, the momentary-loudness scale), however fine the bars: RMS over
// less than a beat converges back to peak, and the oversampling styles'
// one-chunk bars would peg on every kick. Only the level is floored; the
// min/max shape keeps per-bar resolution.
static const NSUInteger kVibeWaveformEnergyColumns = 1024;

// The energy column bar i of count draws, of MIN(count,
// kVibeWaveformEnergyColumns): its own until the bars are finer than the
// floor.
static inline NSUInteger VibeWaveformEnergyColumnIndexForBar(NSUInteger i, NSUInteger count) {
    return count > kVibeWaveformEnergyColumns
            ? i * kVibeWaveformEnergyColumns / count : i;
}

// How much of AudioWaveform.getBarMeanSquares's reach count bars take: all of
// it up to fullCount, fading to none at twice that. Bars about a beat long
// need it, or their levels ripple as a resize moves their edges; bars short
// enough to draw each hit do not, and it would fatten every hit by a bar.
static inline float VibeWaveformWindowReach(NSUInteger count, NSUInteger fullCount) {
    return clampRange(2 - (float)count / (float)fullCount, 0, 1);
}

// Normalize only raises levels: its reference cannot exceed the fixed one.
// Silence keeps the fixed reference to avoid division by zero.
static inline float VibeWaveformNormalizedFullScaleRMS(float loudest) {
    return loudest > 0 ? fminf(loudest, kVibeWaveformFullScaleRMS) : kVibeWaveformFullScaleRMS;
}

// The waveform's resolution: a bar finer than a chunk only repeats its
// neighbor. Caps the styles whose count follows the scrubber's zoomed width.
static const NSUInteger kVibeWaveformMaxBars = 8192;
