//
//  WaveformBandSplit.cpp
//  WaveformCore
//

#include "WaveformBandSplit.hpp"

#include <cmath>

namespace wavecore {

// Wide crossovers: at 280 Hz low and mid still answer almost equally, which
// is a shallow crossover's shape. Mid is the low crossover's highpass into
// the high one's lowpass.
static const double kLowCrossoverHz = 300;
static const double kHighCrossoverHz = 2500;

// The RBJ cookbook's 2nd-order Butterworth (Q = 1/√2), normalized by a0: b0,
// b1, b2, then the feedback negated, as direct form I adds it.
static void ButterworthSection(double cutoffHz, double sampleRate, bool highpass, double *section) {
    double w = 2 * M_PI * cutoffHz / sampleRate;
    double cosw = std::cos(w);
    double alpha = std::sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    double edge = highpass ? (1 + cosw) / 2 : (1 - cosw) / 2;
    section[0] = edge / a0;
    section[1] = (highpass ? -2 : 2) * edge / a0;
    section[2] = edge / a0;
    section[3] = 2 * cosw / a0;
    section[4] = -(1 - alpha) / a0;
}

BandSplit::BandSplit(double sampleRate) {
    double sections[4][5];
    ButterworthSection(kLowCrossoverHz, sampleRate, false, sections[0]);
    ButterworthSection(kLowCrossoverHz, sampleRate, true, sections[1]);
    ButterworthSection(kHighCrossoverHz, sampleRate, false, sections[2]);
    ButterworthSection(kHighCrossoverHz, sampleRate, true, sections[3]);
    for (int lane = 0; lane < 4; lane++) {
        b0[lane] = sections[lane][0];
        b1[lane] = sections[lane][1];
        b2[lane] = sections[lane][2];
        a1[lane] = sections[lane][3];
        a2[lane] = sections[lane][4];
    }
}

// The four sections run side by side, so a sample costs one section's
// latency: mid's lowpass takes its highpass's output from two samples back,
// which leaves no lane waiting on another within a sample. The mid band lags
// the others by two samples. Double precision limits rounding near the unit
// circle at high sample rates.
void BandSplit::addSumSquares(const float *mono, size_t frames, double *sums) {
    // Locals, so the stores through sums cannot alias the state.
    simd_double4 x1 = this->x1, x2 = this->x2, y1 = this->y1, y2 = this->y2;
    simd_double4 squares = 0;
    for (size_t i = 0; i < frames; i++) {
        double x = mono[i];
        simd_double4 in = {x, x, y2[1], x};
        simd_double4 y = a1 * y1 + (b0 * in + b1 * x1 + b2 * x2 + a2 * y2);
        squares += y * y;
        x2 = x1;
        x1 = in;
        y2 = y1;
        y1 = y;
    }
    // A corrupt file's NaN or Inf stays in a section's state forever: reset
    // it, so the band loses this slice rather than the rest of the file.
    for (int lane = 0; lane < 4; lane++) {
        if (!std::isfinite(x1[lane] + x2[lane] + y1[lane] + y2[lane])) {
            x1[lane] = x2[lane] = y1[lane] = y2[lane] = 0;
        }
    }
    this->x1 = x1;
    this->x2 = x2;
    this->y1 = y1;
    this->y2 = y2;
    const int bandLanes[kBandCount] = {0, 2, 3};
    for (size_t b = 0; b < kBandCount; b++) {
        if (std::isfinite(squares[bandLanes[b]])) sums[b] += squares[bandLanes[b]];
    }
}

}  // namespace wavecore
