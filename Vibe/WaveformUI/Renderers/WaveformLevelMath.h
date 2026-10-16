//
//  WaveformLevelMath.h
//  Vibe
//
//  Level mapping, display gain, bar counts and Spectrum color mixing.
//  Header-only for tests without the renderers' C++ or Core Animation.
//

#import <Foundation/Foundation.h>
#import <math.h>
#import <simd/simd.h>
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

// Mix sRGB primaries by the fourth power of the band RMS ratios.
// Restore the weighted primary brightness. Silence uses the plain mean.
// Levels may exceed one; only their ratios matter.
static inline void VibeSpectrumColor(const float *levels, const float primaries[3][3], float *rgb) {
    simd_float3 level = simd_max(simd_make_float3(levels[0], levels[1], levels[2]), 0);
    simd_float3 energy = level * level;
    simd_float3 weights = energy * energy;
    float total = weights.x + weights.y + weights.z;
    if (total <= 0) {
        for (int c = 0; c < 3; c++) {
            rgb[c] = (primaries[0][c] + primaries[1][c] + primaries[2][c]) / 3;
        }
        return;
    }
    simd_float4 mixed = 0;
#pragma clang loop unroll(full)
    for (int b = 0; b < 3; b++) {
        float weight = weights[b] / total;
        float brightness = fmaxf(primaries[b][0], fmaxf(primaries[b][1], primaries[b][2]));
        mixed += weight * simd_make_float4(primaries[b][0], primaries[b][1], primaries[b][2], brightness);
    }
    float peak = fmaxf(mixed.x, fmaxf(mixed.y, mixed.z));
    float scale = peak > 0 ? mixed.w / peak : 0;
    mixed *= scale;
    memcpy(rgb, &mixed, 3 * sizeof(float));
}

// A bar's level averages energy over a column no finer than 1/1024 of the
// track, regardless of the drawn columns. RMS over less than a beat
// converges back to peak, and the oversampling styles' short columns would
// peg on every kick. Only the level is floored. The min/max shape keeps each
// column's own resolution.
static const NSUInteger kVibeWaveformEnergyColumns = 1024;

// Spectrum's color window is a tent 1/256 of the track from foot to foot,
// about two beats on a typical track, so its weight is a beat's. A bar-long
// box alternates between the kick's and the hats' hues from pixel to pixel,
// and the comb crawls as a resize slides the windows. A beat-long box still
// leaks a fifth of the beat, which at narrow widths beats against the pixel
// pitch. The tent's leakage is the square of that. Coarser than the level
// floor, because a bar's height may show each hit while its color should not.
static const NSUInteger kVibeWaveformSpectrumColorColumns = 256;

// How much of AudioWaveform.meanSquares's reach count bars take: all of
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
