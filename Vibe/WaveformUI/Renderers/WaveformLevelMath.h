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

// A level is the RMS of the loudest short window a bar covers
// (WaveformCore's Column.loudest), so the hits stand above the sound around
// them. Not peaks: on a limited master every coarse bar holds a full-scale
// peak and the strip reads as a block, while the loudest window still rises
// on each kick. Not a mean: over a coarse bar it averages each hit away. Full
// height is -6 dBFS over that window, a loud master's kick; hotter clamps.
static const float kVibeWaveformFullScaleRMS = 0.5f;

// Gain is a display gain ahead of the clamp and also a curve bend: the
// exponent doubles per this many dB down (expanding a pegged master's
// variation) and halves per as many up (compressing, as a limiter reads).
static const float kVibeWaveformGainDBPerExponentDoubling = 24.0f;

// fullScaleRMS draws full height at 0 dB: the fixed reference, or under
// Normalize one the track measures (WaveformRenderer.h).
static inline float VibeWaveformBarLevel(float rms, float fullScaleRMS, float gainDB) {
    float level = fmaxf(rms, 0.0f) / fullScaleRMS;
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

// The Detailed types read their levels on a grid no finer than 1/1024 of the
// track, regardless of the drawn columns. Zoomed in, the stream's own shape
// then draws under one smooth gain, and the sample line stays the line. Only
// the level is floored. The min/max shape keeps each column's own resolution.
static const NSUInteger kVibeWaveformLevelColumns = 1024;

// Spectrum's color window is a tent 1/256 of the track from foot to foot,
// about two beats on a typical track, so its weight is a beat's. A bar-long
// box alternates between the kick's and the hats' hues from pixel to pixel,
// and the comb crawls as a resize slides the windows. A beat-long box still
// leaks a fifth of the beat, which at narrow widths beats against the pixel
// pitch. The tent's leakage is the square of that. Coarser than the level
// floor, because a bar's height may show each hit while its color should not.
static const NSUInteger kVibeWaveformSpectrumColorColumns = 256;
