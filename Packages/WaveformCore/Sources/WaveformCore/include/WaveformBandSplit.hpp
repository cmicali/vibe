//
//  WaveformBandSplit.hpp
//  WaveformCore
//

#pragma once

#include "WaveformSummary.hpp"

#include <simd/simd.h>

namespace wavecore {

// The streaming three-band split: fed a mono stream in order, it filters each
// slice and adds every band's sum of squares. The filters' state carries
// across calls, so the split sees no slice edges. 2nd-order Butterworth
// crossovers at 300 Hz and 2.5 kHz, the handovers measured off a CDJ-3000's
// 3-band display.
class BandSplit {
public:
    explicit BandSplit(double sampleRate);

    // Adds each band's sum of squares over the frames to sums, low to high.
    void addSumSquares(const float *mono, size_t frames, double *sums);

private:
    // Each crossover's poles, run two samples ahead. a1 and minusA2 are the
    // input taps. ahead2 and ahead4 are the feedback.
    struct Recursion {
        double a1, minusA2, ahead2, ahead4;
    };
    Recursion low_, high_;
    // Mid's taps on the low recursion, then on the high one.
    std::array<double, 5> mid_;
    // Each band's sum takes back the gain its taps leave out.
    std::array<double, kBandCount> gains_;
    // Pairs of consecutive samples, oldest first: the last two inputs, and
    // each recursion's last four outputs.
    simd_double2 x2_ = 0, low2_ = 0, low4_ = 0, high2_ = 0, high4_ = 0;
};

}  // namespace wavecore
