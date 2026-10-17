//
//  WaveformBandSplit.cpp
//  WaveformCore
//

#include "WaveformBandSplit.hpp"

#include <cmath>
#include <cstring>

namespace wavecore {

// Wide crossovers: at 280 Hz low and mid still answer almost equally, which
// is a shallow crossover's shape. Mid is the low crossover's highpass into
// the high one's lowpass.
static const double kLowCrossoverHz = 300;
static const double kHighCrossoverHz = 2500;

namespace {

// The RBJ cookbook's 2nd-order Butterworth (Q = 1/√2), normalized by a0. Its
// poles are A(z) = 1 - a1 z^-1 - a2 z^-2. Its numerators are lowpass times
// (1, 2, 1) and highpass times (1, -2, 1).
struct Butterworth {
    double a1, a2, lowpass, highpass;
};
Butterworth ButterworthAt(double cutoffHz, double sampleRate) {
    double w = 2 * M_PI * cutoffHz / sampleRate;
    double cosw = std::cos(w);
    double alpha = std::sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    return {2 * cosw / a0, -(1 - alpha) / a0, (1 - cosw) / 2 / a0, (1 + cosw) / 2 / a0};
}

}  // namespace

// Each crossover's poles run once, as w = x / A(z). Every band is then a few
// taps of those two recursions. Low is (1, 2, 1) of the low one's, and high
// is (1, -2, 1) of the high one's. Mid is low's highpass into high's lowpass:
// (1 - z^-2)^2 over both crossovers' poles. In partial fractions that is
// three taps of the low recursion plus two of the high one, so mid needs no
// recursion of its own. A cascade would wait on the low crossover's output.
//
// Each recursion runs two samples ahead. Multiplied through by A(-z), its
// feedback has only even powers: w[n] = (a1² + 2 a2) w[n-2] - a2² w[n-4] +
// x[n] + a1 x[n-1] - a2 x[n-2]. So even and odd samples are two independent
// recursions, and a pair of consecutive samples fills one vector.
// TRAP: never add feedback taps by substituting w[n-1] instead. That also
// runs ahead, but the poles it adds lie outside the unit circle, and the
// recursion blows up. A(-z)'s poles mirror the real ones, so they are as
// stable.
BandSplit::BandSplit(double sampleRate) {
    Butterworth low = ButterworthAt(kLowCrossoverHz, sampleRate);
    Butterworth high = ButterworthAt(kHighCrossoverHz, sampleRate);
    low_ = {low.a1, -low.a2, low.a1 * low.a1 + 2 * low.a2, -low.a2 * low.a2};
    high_ = {high.a1, -high.a2, high.a1 * high.a1 + 2 * high.a2, -high.a2 * high.a2};
    // 1 - 2 z^-2 + z^-4 = P(z) A_high(z) + Q(z) A_low(z), with three taps in
    // P and two in Q. Only P's last tap reaches z^-4. The other four solve
    // the powers below it.
    double p2 = -1 / high.a2;
    simd_double4x4 poles = simd_matrix(simd_make_double4(1, -high.a1, -high.a2, 0),
                                       simd_make_double4(0, 1, -high.a1, -high.a2),
                                       simd_make_double4(1, -low.a1, -low.a2, 0),
                                       simd_make_double4(0, 1, -low.a1, -low.a2));
    simd_double4 taps = simd_mul(simd_inverse(poles), simd_make_double4(1, 0, -2 - p2, high.a1 * p2));
    mid_ = {taps[0], taps[1], p2, taps[2], taps[3]};
    double midGain = low.highpass * high.lowpass;
    gains_ = {low.lowpass * low.lowpass, midGain * midGain, high.highpass * high.highpass};
}

void BandSplit::addSumSquares(const float *mono, size_t frames, double *sums) {
    // Locals, so the stores through sums cannot alias the state.
    const Recursion lo = low_, hi = high_;
    const double m0 = mid_[0], m1 = mid_[1], m2 = mid_[2], m3 = mid_[3], m4 = mid_[4];
    simd_double2 x2 = x2_, low2 = low2_, low4 = low4_, high2 = high2_, high4 = high4_;
    simd_double2 lowSquares = 0, midSquares = 0, highSquares = 0;
    // Samples n and n + 1 from their inputs: each recursion's pair, the pair
    // one sample earlier, and the bands.
    simd_double2 x1, l, h, l1, h1, low, mid, high;
    auto step = [&](simd_double2 x0) __attribute__((always_inline)) {
        x1 = simd_make_double2(x2[1], x0[0]);
        l = simd_muladd(lo.ahead2, low2, simd_muladd(lo.ahead4, low4,
                simd_muladd(lo.minusA2, x2, simd_muladd(lo.a1, x1, x0))));
        h = simd_muladd(hi.ahead2, high2, simd_muladd(hi.ahead4, high4,
                simd_muladd(hi.minusA2, x2, simd_muladd(hi.a1, x1, x0))));
        l1 = simd_make_double2(low2[1], l[0]);
        h1 = simd_make_double2(high2[1], h[0]);
        low = simd_muladd(2, l1, l + low2);
        high = simd_muladd(-2, h1, h + high2);
        mid = simd_muladd(m4, h1, simd_muladd(m3, h, simd_muladd(m2, low2, simd_muladd(m1, l1, m0 * l))));
    };
    size_t i = 0;
    for (; i + 2 <= frames; i += 2) {
        simd_float2 in;
        std::memcpy(&in, mono + i, sizeof(in));
        simd_double2 x0 = simd_double(in);
        step(x0);
        lowSquares = simd_muladd(low, low, lowSquares);
        midSquares = simd_muladd(mid, mid, midSquares);
        highSquares = simd_muladd(high, high, highSquares);
        x2 = x0;
        low4 = low2;
        low2 = l;
        high4 = high2;
        high2 = h;
    }
    if (i < frames) {
        // A last odd sample is a pair's first lane. The second lane is unused.
        step(simd_make_double2(mono[i], 0));
        lowSquares[0] += low[0] * low[0];
        midSquares[0] += mid[0] * mid[0];
        highSquares[0] += high[0] * high[0];
        x2 = x1;
        low4 = simd_make_double2(low4[1], low2[0]);
        low2 = l1;
        high4 = simd_make_double2(high4[1], high2[0]);
        high2 = h1;
    }
    // A corrupt file's NaN or Inf stays in the recursions forever: reset
    // them, so the bands lose this slice rather than the rest of the file.
    // Every recursion reads the same input, so one test covers them all.
    // x - x is 0 only for a finite x.
    simd_double2 state = x2 + low2 + low4 + high2 + high4;
    if (!simd_all(state - state == 0)) {
        x2 = low2 = low4 = high2 = high4 = 0;
    }
    x2_ = x2;
    low2_ = low2;
    low4_ = low4;
    high2_ = high2;
    high4_ = high4;
    double bands[kBandCount] = {simd_reduce_add(lowSquares) * gains_[0], simd_reduce_add(midSquares) * gains_[1],
                                simd_reduce_add(highSquares) * gains_[2]};
    for (size_t b = 0; b < kBandCount; b++) {
        if (std::isfinite(bands[b])) sums[b] += bands[b];
    }
}

}  // namespace wavecore
