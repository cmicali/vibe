//
//  WaveformLevelMath.h
//  Vibe
//
//  The chunk-to-level mapping every bar style draws from, and the one gain
//  setting that bends it. Spectrum's color mix is here too. Header-only and
//  Foundation-free, so both are testable without the renderer headers' C++
//  and Core Animation imports.
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

// Spectrum's color for one bar from its low, mid and high levels, each an
// sRGB primary. The weights are the bands' energies, so the loudest band leads
// the hue. The mix is then brightened back to the primaries' own brightness,
// as an additive mix is. Low and high alone make the two primaries' sum, a
// purple. No single tone can make it. A lone band is its primary exactly.
// Silence is the primaries' plain mean, a gray left unbrightened. Brightened,
// the light set's gray would vanish on white.
static inline void VibeSpectrumColor(const float *levels, const float primaries[3][3], float *rgb) {
    float weights[3];
    float total = 0;
    for (int b = 0; b < 3; b++) {
        float level = fmaxf(levels[b], 0.0f);
        weights[b] = level * level;
        total += weights[b];
    }
    if (total <= 0) {
        for (int c = 0; c < 3; c++) {
            rgb[c] = (primaries[0][c] + primaries[1][c] + primaries[2][c]) / 3;
        }
        return;
    }
    float brightness = 0;
    rgb[0] = rgb[1] = rgb[2] = 0;
    for (int b = 0; b < 3; b++) {
        float weight = weights[b] / total;
        brightness += weight * fmaxf(primaries[b][0], fmaxf(primaries[b][1], primaries[b][2]));
        for (int c = 0; c < 3; c++) {
            rgb[c] += weight * primaries[b][c];
        }
    }
    float peak = fmaxf(rgb[0], fmaxf(rgb[1], rgb[2]));
    float scale = peak > 0 ? brightness / peak : 0;
    for (int c = 0; c < 3; c++) {
        rgb[c] *= scale;
    }
}
