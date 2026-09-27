//
//  WaveformLevelMath.h
//  Vibe
//
//  The chunk-to-level mapping every bar style draws from, and the one gain
//  setting that bends it. Header-only and Foundation-free so the mapping is
//  testable without the renderer headers' C++ and Core Animation imports.
//

#import <math.h>

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
