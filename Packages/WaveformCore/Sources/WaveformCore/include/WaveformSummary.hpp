//
//  WaveformSummary.hpp
//  WaveformCore
//
//  A waveform summary: per-bin peaks and energy on a grid of absolute time,
//  the multi-level reads every display is drawn from, and its archive form.
//  Plain C++17 over Accelerate and Compression. No app types.
//

#pragma once

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace wavecore {

// Low, mid and high (BandSplit).
constexpr size_t kBandCount = 3;
// Channels a summary stores. A file with more stores its mono mix.
constexpr uint32_t kMaxChannels = 2;
// The finest bin a long file stores: 5.8 ms at 44.1 kHz.
constexpr uint32_t kBaseBinFrames = 256;
// Short files take finer bins, down to one frame, until they hold this many.
constexpr int64_t kMinimumBins = 8192;
// Read extremes through the coarsest level that still puts this many bins in
// a column, so a column's edges move by at most an eighth of it.
constexpr double kBinsPerColumn = 8;

// 256 frames, or a finer power of two for a file too short to fill
// kMinimumBins at 256.
uint32_t BinFramesForLength(int64_t frames);

// Asks for the union of every stored channel.
constexpr int kAllChannels = -1;

// What a stretch of frames holds. lo and hi are the extremes of the frames it
// covers, the sums cover exactly `frames` of them.
struct Column {
    float lo = 0;
    float hi = 0;
    double sumSquares = 0;
    double frames = 0;
    std::array<double, kBandCount> bandSumSquares = {0, 0, 0};

    float meanSquare() const { return frames > 0 ? float(sumSquares / frames) : 0.0f; }
    float bandMeanSquare(size_t band) const { return frames > 0 ? float(bandSumSquares[band] / frames) : 0.0f; }
    float extent() const { return std::fmax(std::fabs(lo), std::fabs(hi)); }
};

class Summary {
public:
    Summary(uint32_t binFrames, uint32_t channels, bool bands, double sampleRate);
    Summary(const Summary &) = delete;
    Summary &operator=(const Summary &) = delete;

    uint32_t binFrames() const { return binFrames_; }
    uint32_t channels() const { return channels_; }
    bool hasBands() const { return bands_; }
    double sampleRate() const { return sampleRate_; }
    size_t binCount() const { return base_.count; }
    // Frames the bins hold.
    int64_t frames() const { return frames_; }
    // Frames a view spans: the decode's expected length until complete, then
    // the frames it read. A view lays the summary out on it, so a streaming
    // load's bins land where they will stay.
    int64_t totalFrames() const { return complete_ ? frames_ : std::max(totalFrames_, frames_); }
    bool isComplete() const { return complete_; }
    double decodedFraction() const;

    // Frames [first, last), clipped to the frames held. Extremes are exact
    // unions, a straddling base bin taken whole so a peak is never lost.
    // Sums are exact, a straddling base bin counted by its part.
    Column column(double first, double last, int channel = kAllChannels) const;
    // Column k of the grid covers [k F, (k + 1) F). count columns from
    // firstIndex into out. The grid counts from frame 0, so a scroll or a
    // window never moves a column's frames.
    void columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out,
                 int channel = kAllChannels) const;
    // Each grid column's mean square, the mix's into mix and the bands' (low
    // to high per column) into bands; either may be null. With reach, a
    // column takes the loudest of five column-long windows a quarter column
    // apart around its own, blended by reach (0 to 1). A window past the
    // frames held is the mean of what it covers.
    void meanSquares(double framesPerColumn, int64_t firstIndex, size_t count, float reach,
                     float *mix, float *bands) const;
    // Each grid column's band mean squares under a tent centred on it,
    // halfWidth frames from centre to foot, into bands (low to high per
    // column). Zeros without bands.
    void tentBandMeanSquares(double framesPerColumn, int64_t firstIndex, size_t count, double halfWidth,
                             float *bands) const;
    // The loudest of meanSquares over `columns` columns spanning the whole
    // summary at this reach: a reference that does not depend on any view.
    // Kept per (columns, reach) while the summary stands.
    void loudestMeanSquares(size_t columns, float reach, float *mix, float *bands) const;

    std::unique_ptr<Summary> copy() const;

    // The archive form: a header and LZFSE-compressed float16 planes. decode
    // answers null for anything malformed or non-finite.
    std::vector<uint8_t> encode() const;
    static std::unique_ptr<Summary> decode(const void *bytes, size_t length);

    // For builders and tests. A bin holds binFrames frames except the last.
    // Before the summary is shared only.
    void appendBin(const float *lo, const float *hi, double sumSquares, const double *bandSumSquares,
                   uint32_t frames);
    void setTotalFrames(int64_t frames) { totalFrames_ = frames; }
    void markComplete() { complete_ = true; }

private:
    struct Level {
        uint64_t binFrames = 0;
        size_t count = 0;
        std::array<std::vector<_Float16>, kMaxChannels> lo;
        std::array<std::vector<_Float16>, kMaxChannels> hi;
        std::vector<float> sumSquares;
        std::vector<float> bandSumSquares;  // kBandCount per bin
    };

    const Level &level(size_t index) const;
    size_t levelCount() const;
    void buildPyramid() const;
    void accumulate(size_t levelIndex, double first, double last, int channel, bool extremes, Column &into) const;
    double binEnd(const Level &level, size_t bin) const;

    uint32_t binFrames_;
    uint32_t channels_;
    bool bands_;
    double sampleRate_;
    int64_t frames_ = 0;
    int64_t totalFrames_ = 0;
    bool complete_ = false;
    Level base_;

    // Built on first read and kept: a shared summary never changes.
    mutable std::mutex lazyLock_;
    mutable std::atomic<bool> pyramidBuilt_{false};
    mutable std::vector<Level> pyramid_;
    struct Loudest {
        size_t columns;
        float reach;
        float mix;
        std::array<float, kBandCount> bands;
    };
    mutable std::vector<Loudest> loudest_;
    // Running sums per level, for the tent: per bin edge the frames' and
    // bands' first and second running sums. An entry is never replaced, so a
    // reader holding one is safe while another builds a second.
    mutable std::vector<std::pair<size_t, std::shared_ptr<const std::vector<double>>>> tentSums_;
};

// Builds a summary from a decode's stream, in order. The mono mix carries the
// energy and the bands; the interleaved samples carry each channel's peaks.
class BandSplit;
class SummaryBuilder {
public:
    // inputChannels is the stride of append's interleaved samples. With
    // storedChannels 2 a stereo input keeps each channel's peaks. Otherwise
    // the summary keeps the mix's.
    SummaryBuilder(uint32_t inputChannels, uint32_t storedChannels, bool bands, int64_t expectedFrames,
                   double sampleRate);
    ~SummaryBuilder();

    void append(const float *interleaved, const float *mono, size_t frames);
    int64_t frames() const { return frames_; }
    void setExpectedFrames(int64_t frames) { summary_->setTotalFrames(frames); }
    // The whole bins so far, for a streaming load's progressive delivery.
    std::unique_ptr<Summary> snapshot() const { return summary_->copy(); }
    // Flushes the partial bin. A complete summary spans exactly what was read.
    std::unique_ptr<Summary> finish(bool complete);

private:
    void flushBin();

    std::unique_ptr<Summary> summary_;
    std::unique_ptr<BandSplit> split_;
    uint32_t inputChannels_;
    uint32_t channels_;
    uint32_t binFrames_;
    int64_t frames_ = 0;
    uint32_t binFill_ = 0;
    std::array<float, kMaxChannels> lo_;
    std::array<float, kMaxChannels> hi_;
    double sumSquares_ = 0;
    std::array<double, kBandCount> bandSumSquares_ = {0, 0, 0};
};

}  // namespace wavecore
