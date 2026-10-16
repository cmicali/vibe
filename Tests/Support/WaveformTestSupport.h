//
//  WaveformTestSupport.h
//  VibeTests
//
//  Waveforms built bin by bin, for the renderer and view tests. ObjC++ only.
//

#import "AudioWaveform.h"

#include <array>
#include <vector>

// A bin's peaks and mean square.
struct VibeTestBin {
    float lo = 0;
    float hi = 0;
    float meanSquare = 0;
};

// One frame a bin unless binFrames says otherwise; bandMeanSquares, when
// given, holds one entry per bin. A bin lasts as long as a real summary's,
// 256 frames at 44.1 kHz, so a loudest window spans three bins as it does
// there.
static inline std::unique_ptr<AudioWaveform> VibeTestWaveform(
        const std::vector<VibeTestBin> &bins,
        const std::vector<std::array<float, wavecore::kBandCount>> &bandMeanSquares = {},
        bool complete = true, uint32_t binFrames = 1) {
    double sampleRate = 44100.0 * binFrames / wavecore::kBaseBinFrames;
    auto waveform = std::make_unique<AudioWaveform>(binFrames, 1, !bandMeanSquares.empty(), sampleRate);
    for (size_t i = 0; i < bins.size(); i++) {
        double bands[wavecore::kBandCount] = {};
        if (!bandMeanSquares.empty()) {
            for (size_t b = 0; b < wavecore::kBandCount; b++) {
                bands[b] = (double)bandMeanSquares[i][b] * binFrames;
            }
        }
        waveform->appendBin(&bins[i].lo, &bins[i].hi, (double)bins[i].meanSquare * binFrames,
                            bandMeanSquares.empty() ? nullptr : bands, binFrames);
    }
    if (complete) {
        waveform->markComplete();
    }
    return waveform;
}

// count bins alike.
static inline std::unique_ptr<AudioWaveform> VibeTestSteadyWaveform(size_t count, VibeTestBin bin,
                                                                     bool complete = true) {
    return VibeTestWaveform(std::vector<VibeTestBin>(count, bin), {}, complete);
}

// The extremes of column i of count across the whole waveform.
static inline wavecore::Column VibeTestColumn(AudioWaveform *waveform, NSUInteger i, NSUInteger count) {
    double frames = (double)waveform->totalFrames() / (double)count;
    return waveform->column(i * frames, (i + 1) * frames);
}
