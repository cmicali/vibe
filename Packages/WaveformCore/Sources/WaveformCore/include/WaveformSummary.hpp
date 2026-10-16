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
#include <utility>
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
// A level is the loudest window this long a column covers, about a kick's
// body. A column's mean would average each hit into the frames around it.
constexpr double kTransientSeconds = 0.02;

// 256 frames, or a finer power of two for a file too short to fill
// kMinimumBins at 256.
uint32_t BinFramesForLength(int64_t frames);

// Asks for the union of every stored channel.
constexpr int kAllChannels = -1;

// What a stretch of frames holds. lo and hi are the extremes of the frames it
// covers, the sums cover exactly `frames` of them. loudest is the RMS of the
// loudest kTransientSeconds window centred on a bin it covers, in the mix and
// in each band. Like the extremes it is a union, so no hit is ever averaged
// away and no column edge can hide one.
struct Column {
    float lo = 0;
    float hi = 0;
    double sumSquares = 0;
    double frames = 0;
    std::array<double, kBandCount> bandSumSquares = {0, 0, 0};
    float loudest = 0;
    std::array<float, kBandCount> bandLoudest = {0, 0, 0};

    float meanSquare() const { return frames > 0 ? float(sumSquares / frames) : 0.0f; }
    float bandMeanSquare(size_t band) const { return frames > 0 ? float(bandSumSquares[band] / frames) : 0.0f; }
    float extent() const { return std::fmax(std::fabs(lo), std::fabs(hi)); }
};

// A stream's own frames as the mix, held in blocks a caller fills on demand:
// what a column finer than a summary's bins reads. Blocks may arrive on any
// thread while reads run, and the oldest go first past kMaxBlocks.
class Detail {
public:
    static constexpr int64_t kBlockFrames = 1 << 16;
    static constexpr size_t kMaxBlocks = 16;
    // TRAP: a read crosses at most half the blocks held. Reads that need more
    // than are held evict a block they need with each one read in, and ask
    // for it again forever.
    static constexpr size_t kMaxReadBlocks = kMaxBlocks / 2;

    // The mix's samples for the frames from block * kBlockFrames. A block
    // shorter than kBlockFrames ends the stream.
    void insertBlock(int64_t block, std::vector<float> samples);
    bool hasBlock(int64_t block) const;
    // Every insert counts, so a reader can tell that columns it read before
    // may read finer now.
    uint64_t insertCount() const;
    // Columns of the grid of F frames from firstIndex, of a stream of
    // `frames`, read through the line joining the samples at their frames'
    // centers. So a column narrower than a frame holds the line's span across
    // it. Each column's loudest is its own RMS. false, leaving out as it was,
    // when the columns cross more than kMaxReadBlocks or a block that is
    // missing.
    bool columns(double framesPerColumn, int64_t firstIndex, size_t count, int64_t frames, Column *out) const;
    // The blocks the last read that missed some lacked, which a holder reads
    // in. Taken once, so a block that cannot be read is asked for again only
    // by a later read.
    std::vector<int64_t> takeLackedBlocks();

private:
    mutable std::mutex lock_;
    std::vector<std::pair<int64_t, std::shared_ptr<const std::vector<float>>>> blocks_;  // oldest first
    mutable std::vector<int64_t> lacked_;
    uint64_t inserts_ = 0;
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
    // window never moves a column's frames. Columns finer than a bin read
    // the mix's own frames where the detail holds every one they cross.
    void columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out,
                 int channel = kAllChannels) const;
    // Each grid column's band mean squares under a tent centred on it,
    // halfWidth frames from centre to foot, into bands (low to high per
    // column). Zeros without bands.
    void tentBandMeanSquares(double framesPerColumn, int64_t firstIndex, size_t count, double halfWidth,
                             float *bands) const;
    // The stream's frames for deep zoom, filled by whoever holds the summary.
    // A copy starts without them.
    Detail &detail() const { return detail_; }

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
        // Derived with the pyramid, never archived: the loudest window's RMS.
        mutable std::vector<_Float16> loudest;
        mutable std::vector<_Float16> bandLoudest;  // kBandCount per bin
    };

    friend class SummaryBuilder;

    const Level &level(size_t index) const;
    size_t levelCount() const;
    void buildPyramid() const;
    void buildLoudest() const;
    void accumulate(size_t levelIndex, double first, double last, int channel, Column &into) const;
    double binEnd(const Level &level, size_t bin) const;
    double binWidth(const Level &level, size_t bin) const { return binEnd(level, bin) - double(bin * level.binFrames); }

    uint32_t binFrames_;
    uint32_t channels_;
    bool bands_;
    double sampleRate_;
    int64_t frames_ = 0;
    int64_t totalFrames_ = 0;
    bool complete_ = false;
    Level base_;

    // The pyramid and the loudest windows. Built where a summary is made (a
    // copy, a decode, a builder's finish), or else on first read, and kept: a
    // shared summary never changes.
    mutable std::mutex lazyLock_;
    mutable std::atomic<bool> pyramidBuilt_{false};
    mutable std::vector<Level> pyramid_;
    // Running sums per level, for the tent: per bin edge the frames' and
    // bands' first and second running sums. An entry is never replaced, so a
    // reader holding one is safe while another builds a second.
    mutable std::vector<std::pair<size_t, std::shared_ptr<const std::vector<double>>>> tentSums_;
    mutable Detail detail_;
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
    uint32_t binFill_ = 0;
    std::array<float, kMaxChannels> lo_;
    std::array<float, kMaxChannels> hi_;
    double sumSquares_ = 0;
    std::array<double, kBandCount> bandSumSquares_ = {0, 0, 0};
};

}  // namespace wavecore
