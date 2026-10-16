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
    // One lane per 2nd-order section: low, mid's highpass, mid's lowpass,
    // high. Direct form I.
    simd_double4 b0, b1, b2, a1, a2;
    simd_double4 x1 = 0, x2 = 0, y1 = 0, y2 = 0;
};

}  // namespace wavecore
