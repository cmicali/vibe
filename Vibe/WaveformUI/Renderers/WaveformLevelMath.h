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

// Spectrum's color window is a tent this many seconds from centre to foot.
// A column's color is then its bar's mix, while its height still shows each
// hit. A shorter window leaks the bar's own pattern, and a drum loop shows
// as stripes a bar apart. At 2 s the beat, the backbeat and a one-bar
// pattern each leak under 5% from 100 to 174 BPM. The window is fixed in
// time. As a share of the track, it was a beat long on a short track.
static const double kVibeWaveformSpectrumColorSeconds = 2.0;

// By section's grid. A column is half a second, about a beat, or 1/512 of a
// track too long for that. A section is at least 8 columns long. The grid
// follows the track, not the drawn columns, so a resize or a zoom never moves
// a section's edge. An enum, since C sizes arrays only by a constant
// expression.
enum { kVibeWaveformSectionColumns = 512, kVibeWaveformSectionMinColumns = 8 };
static const double kVibeWaveformSectionColumnSeconds = 0.5;
// The cost of one more section, against each column's squared distance from
// its section's mix. Raising it merges sections.
static const double kVibeWaveformSectionPenalty = 1.0;

// The frames of one grid column for a track of totalFrames.
static inline double VibeWaveformSectionFramesPerColumn(double totalFrames, double sampleRate) {
    return fmax(kVibeWaveformSectionColumnSeconds * sampleRate, totalFrames / (double)kVibeWaveformSectionColumns);
}

// Replaces each column's band mean squares, low to high, with its section's
// mean. The sections are the fit, constant per section, of each column's mix
// that has the least squared error plus the penalty per section. A column's
// mix is VibeSpectrumColor's weights over shares, the bands' shares of full
// scale. A silent column has no mix, and the fit ignores it. Exact dynamic
// programming, quadratic in count, which is at most
// kVibeWaveformSectionColumns.
static inline void VibeWaveformSectionMeanSquares(float *meanSquares, NSUInteger count, const float shares[3]) {
    count = MIN(count, (NSUInteger)kVibeWaveformSectionColumns);
    if (count == 0) {
        return;
    }
    NSUInteger minimum = MIN((NSUInteger)kVibeWaveformSectionMinColumns, count);
    // Running sums over the columns: how many sound, their mixes and the
    // mixes' squared lengths.
    double sounding[kVibeWaveformSectionColumns + 1] = {0};
    double mix[kVibeWaveformSectionColumns + 1][3] = {{0}};
    double squared[kVibeWaveformSectionColumns + 1] = {0};
    for (NSUInteger j = 0; j < count; j++) {
        double weights[3], total = 0;
        for (int b = 0; b < 3; b++) {
            double energy = fmax(meanSquares[j * 3 + b], 0) / ((double)shares[b] * shares[b]);
            weights[b] = energy * energy;
            total += weights[b];
        }
        sounding[j + 1] = sounding[j] + (total > 0);
        squared[j + 1] = squared[j];
        for (int b = 0; b < 3; b++) {
            double share = total > 0 ? weights[b] / total : 0;
            mix[j + 1][b] = mix[j][b] + share;
            squared[j + 1] += share * share;
        }
    }
    // best[j] is the least cost of the first j columns. start[j] is where its
    // last section starts.
    double best[kVibeWaveformSectionColumns + 1];
    NSUInteger start[kVibeWaveformSectionColumns + 1] = {0};
    best[0] = 0;
    for (NSUInteger j = 1; j <= count; j++) {
        best[j] = INFINITY;
        for (NSUInteger i = 0; i + minimum <= j; i++) {
            if (best[i] == INFINITY) {
                continue;
            }
            double n = sounding[j] - sounding[i], error = squared[j] - squared[i];
            for (int b = 0; n > 0 && b < 3; b++) {
                double sum = mix[j][b] - mix[i][b];
                error -= sum * sum / n;
            }
            double cost = best[i] + error + kVibeWaveformSectionPenalty;
            if (cost < best[j]) {
                best[j] = cost;
                start[j] = i;
            }
        }
    }
    for (NSUInteger end = count; end > 0; end = start[end]) {
        NSUInteger begin = start[end];
        for (int b = 0; b < 3; b++) {
            double sum = 0;
            for (NSUInteger j = begin; j < end; j++) {
                sum += meanSquares[j * 3 + b];
            }
            float mean = (float)(sum / (double)(end - begin));
            for (NSUInteger j = begin; j < end; j++) {
                meanSquares[j * 3 + b] = mean;
            }
        }
    }
}
