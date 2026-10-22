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
// (the summary's Column.loudest), so the hits stand above the sound around
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

// Spectrum's weights: the fourth power of each band's RMS level. Levels may
// exceed one; only their ratios matter.
static inline simd_float3 VibeSpectrumWeights(const float *levels) {
    simd_float3 level = simd_max(simd_make_float3(levels[0], levels[1], levels[2]), 0);
    simd_float3 energy = level * level;
    return energy * energy;
}

// Each band's share of the fixed full scale, from a typical mix's balance.
// Without Normalize 3-Band measures each band against its share, and
// Spectrum's color levels divide by it. Both weigh the mids and highs up
// against music's falling spectrum.
static const float kVibeWaveformBandShares[3] = {1.0f, 0.48f, 0.48f};

// A column's mix from its band mean squares: each band's share of
// VibeSpectrumWeights at the levels Spectrum reads, RMS over the band's share
// of full scale (kVibeWaveformBandShares, or a test's). NO, and no mix, for
// silence.
static inline BOOL VibeSpectrumMix(const float *meanSquares, const float shares[3], float *mix) {
    float levels[3];
    for (int b = 0; b < 3; b++) {
        levels[b] = sqrtf(fmaxf(meanSquares[b], 0)) / shares[b];
    }
    simd_float3 weights = VibeSpectrumWeights(levels);
    float total = weights.x + weights.y + weights.z;
    for (int b = 0; b < 3; b++) {
        mix[b] = total > 0 ? weights[b] / total : 0;
    }
    return total > 0;
}

// Mix sRGB primaries by VibeSpectrumWeights. Restore the weighted primary
// brightness. Silence uses the plain mean.
static inline void VibeSpectrumColor(const float *levels, const float primaries[3][3], float *rgb) {
    simd_float3 weights = VibeSpectrumWeights(levels);
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

// A peak of the run, read from either end.
static inline float VibeWaveformSnapPeak(const float *peaks, NSUInteger count, NSUInteger i, BOOL mirrored) {
    return peaks[mirrored ? count - 1 - i : i];
}

// The edge onto a hit the second side starts with. Mirrored, the first side
// ends with it.
static inline NSUInteger VibeWaveformSnapOntoHit(const float *peaks, NSUInteger count, NSUInteger at, BOOL mirrored) {
    float loudest = 0;
    for (NSUInteger i = 0; i < count; i++) {
        loudest = fmaxf(loudest, peaks[i]);
    }
    float loud = loudest / 2;
    if (VibeWaveformSnapPeak(peaks, count, at, mirrored) >= loud) {
        while (at > 0 && VibeWaveformSnapPeak(peaks, count, at - 1, mirrored) >= loud) {
            at--;
        }
    } else {
        while (at < count && VibeWaveformSnapPeak(peaks, count, at, mirrored) < loud) {
            at++;
        }
    }
    // The quiet side's level, without the hit's own cells.
    double quiet = 0;
    for (NSUInteger i = 0; i < at; i++) {
        quiet += VibeWaveformSnapPeak(peaks, count, i, mirrored);
    }
    quiet = at > 0 ? quiet / (double)at : 0;
    while (at > 0) {
        float soft = VibeWaveformSnapPeak(peaks, count, at - 1, mirrored);
        if (!(soft > quiet * 1.5 && soft <= VibeWaveformSnapPeak(peaks, count, MIN(at, count - 1), mirrored))) {
            break;
        }
        at--;
    }
    return at;
}

// An edge the levels place, moved onto the hit that makes it. peaks are the
// mix's peaks in count cells, and at is the cell the levels start the second
// side on. The bands' levels lag a kick's attack by its 40 to 60 ms build,
// so a split by levels lands inside the kick. When the second side's peaks
// are louder, the edge moves to the start of the loud run around it. When
// they are quieter, to the end of the run before it. A run is the cells at
// least half the loudest peak. A hit's soft start, still rising and louder
// than the quiet side, joins its run. Sides within a quarter of each other
// are left alone, since their peaks mark no hit.
static inline NSUInteger VibeWaveformSectionSnapToHit(const float *peaks, NSUInteger count, NSUInteger at) {
    if (count < 2 || at == 0 || at >= count) {
        return at;
    }
    double before = 0, after = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if (i < at) {
            before += peaks[i];
        } else {
            after += peaks[i];
        }
    }
    before /= (double)at;
    after /= (double)(count - at);
    if (after > before * 1.25) {
        at = VibeWaveformSnapOntoHit(peaks, count, at, NO);
    } else if (before > after * 1.25) {
        at = count - VibeWaveformSnapOntoHit(peaks, count, count - at, YES);
    }
    return MIN(MAX(at, (NSUInteger)1), count - 1);
}

// 3-Band's and Spectrum's heights take the peaks' shape once their columns
// are finer than a kick's build. Zoomed out, a column's loudest window is its
// height, and it rises on each hit. Zoomed in, a kick's low band builds over
// 40 to 60 ms after its attack, so it rose late and round while the peaks
// jump at once. The peaks' weight fades in from pixels of the first figure to
// pixels of the second, by octaves, so a pinch changes the outline
// continuously.
static const double kVibeWaveformPeakShapeFromSeconds = 0.02;
static const double kVibeWaveformPeakShapeToSeconds = 0.005;
static inline double VibeWaveformPeakShapeWeight(double secondsPerPixel) {
    if (!(secondsPerPixel > 0)) {
        return 0;
    }
    double octaves = log2(kVibeWaveformPeakShapeFromSeconds / kVibeWaveformPeakShapeToSeconds);
    return fmin(fmax(log2(kVibeWaveformPeakShapeFromSeconds / secondsPerPixel) / octaves, 0), 1);
}

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

// Each section's first column, in order from 0, into starts; answers how many.
// The sections are the fit, constant per section, of each column's mix that
// has the least squared error plus the penalty per section. A column's mix is
// the share of each band in VibeSpectrumWeights, at the levels the renderer
// reads: RMS over the band's share of full scale, from its band mean squares,
// low to high. A silent column has no mix, and the fit ignores it. Exact
// dynamic programming, quadratic in count, which is at most
// kVibeWaveformSectionColumns.
static inline NSUInteger VibeWaveformSectionStarts(const float *meanSquares, NSUInteger count, const float shares[3],
                                                   NSUInteger *starts) {
    count = MIN(count, (NSUInteger)kVibeWaveformSectionColumns);
    NSUInteger minimum = MIN((NSUInteger)kVibeWaveformSectionMinColumns, count);
    // Running sums over the columns: how many sound, their mixes and the
    // mixes' squared lengths.
    double sounding[kVibeWaveformSectionColumns + 1] = {0};
    double mix[kVibeWaveformSectionColumns + 1][3] = {{0}};
    double squared[kVibeWaveformSectionColumns + 1] = {0};
    for (NSUInteger j = 0; j < count; j++) {
        float column[3];
        sounding[j + 1] = sounding[j] + VibeSpectrumMix(meanSquares + j * 3, shares, column);
        squared[j + 1] = squared[j];
        for (int b = 0; b < 3; b++) {
            mix[j + 1][b] = mix[j][b] + column[b];
            squared[j + 1] += (double)column[b] * column[b];
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
    NSUInteger sections = 0;
    for (NSUInteger end = count; end > 0; end = start[end]) {
        starts[sections++] = start[end];
    }
    for (NSUInteger i = 0; i < sections / 2; i++) {
        NSUInteger swap = starts[i];
        starts[i] = starts[sections - 1 - i];
        starts[sections - 1 - i] = swap;
    }
    return sections;
}

// Where a change in the bands' levels splits count cells, three levels each:
// the cell in [1, count) that starts the second side, fitting each side its
// own mean with the least squared error. The section grid is too coarse to
// find an edge. This puts it on the hit that changes the mix: the first kick
// back in, not the column it falls in. 0 when count is under 2.
static inline NSUInteger VibeWaveformSectionSplit(const float *levels, NSUInteger count) {
    if (count < 2) {
        return 0;
    }
    double total[3] = {0};
    for (NSUInteger i = 0; i < count * 3; i++) {
        total[i % 3] += levels[i];
    }
    // The error is the levels' squares less each side's sum squared over its
    // count, so the best split has the most of the latter.
    double left[3] = {0}, best = -INFINITY;
    NSUInteger split = 1;
    for (NSUInteger t = 1; t < count; t++) {
        double explained = 0;
        for (int b = 0; b < 3; b++) {
            left[b] += levels[(t - 1) * 3 + b];
            double right = total[b] - left[b];
            explained += left[b] * left[b] / (double)t + right * right / (double)(count - t);
        }
        if (explained > best) {
            best = explained;
            split = t;
        }
    }
    return split;
}
