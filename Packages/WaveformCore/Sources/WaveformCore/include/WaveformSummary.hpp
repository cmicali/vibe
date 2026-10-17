//
//  WaveformSummary.hpp
//  WaveformCore
//
//  A waveform summary: a mono mix's peaks and energy per bin, on a grid of
//  absolute time, the reads every display is drawn from, and its archive.
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
// The finest bin a long file stores: 5.8 ms at 44.1 kHz.
constexpr uint32_t kBaseBinFrames = 256;
// Short files take finer bins, down to one frame, until they hold this many.
constexpr int64_t kMinimumBins = 8192;
// Long files take coarser bins, so they hold no more than this many: about
// 25 minutes at 44.1 kHz in 256-frame bins. A summary then costs at most
// about 3.5 MB, 9.5 MB with bands, however long the file. A long file needs
// no zoom near its samples. A 66-minute mix keeps 23 ms bins.
constexpr int64_t kMaximumBins = int64_t(1) << 18;
// A progressive snapshot holds at most this many bins: the finest pyramid
// level that fits. So a snapshot costs the same for an hour as for a minute,
// and never holds fewer than kMinimumBins.
constexpr size_t kSnapshotBins = 4 * kMinimumBins;
// A level is the loudest window this long a column covers, about a kick's
// body. A column's mean would average each hit into the frames around it.
constexpr double kTransientSeconds = 0.02;

// 256 frames, or a finer power of two for a file too short to fill
// kMinimumBins at 256, or a coarser one for a file too long to fit
// kMaximumBins.
uint32_t BinFramesForLength(int64_t frames);

// What a stretch of frames holds. lo and hi are the extremes of the frames it
// covers. loudest is the RMS of the loudest kTransientSeconds window centred
// on a bin it covers, in the mix and in each band. All are unions, so no hit
// is ever averaged away and no column edge can hide one.
struct Column {
    float lo = 0;
    float hi = 0;
    float loudest = 0;
    std::array<float, kBandCount> bandLoudest = {0, 0, 0};

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
    // The blocks the reads since the last take lacked, which a holder reads
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
    Summary(uint32_t binFrames, bool bands, double sampleRate);
    Summary(const Summary &) = delete;
    Summary &operator=(const Summary &) = delete;

    uint32_t binFrames() const { return uint32_t(base_.binFrames); }
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

    // Frames [first, last), clipped to the frames held: the exact union of
    // the base bins it touches, a straddling bin taken whole so a peak is
    // never lost.
    Column column(double first, double last) const;
    // Column k of the grid covers [k F, (k + 1) F). count columns from
    // firstIndex into out. The grid counts from frame 0, so a scroll or a
    // window never moves a column's frames. Columns finer than a bin read
    // the mix's own frames block by block, where the detail holds the
    // block, and the bins elsewhere.
    void columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out) const;
    // Each grid column's band mean squares under a tent centred on it,
    // halfWidth frames from centre to foot, into bands (low to high per
    // column). Zeros without bands.
    void tentBandMeanSquares(double framesPerColumn, int64_t firstIndex, size_t count, double halfWidth,
                             float *bands) const;
    // The stream's frames for deep zoom, filled by whoever holds the summary.
    // A snapshot starts without them.
    Detail &detail() const { return detail_; }

    // The archive form: a header and LZFSE-compressed float16 planes. decode
    // answers null for anything malformed or non-finite.
    std::vector<uint8_t> encode() const;
    static std::unique_ptr<Summary> decode(const void *bytes, size_t length);

    // For builders and tests. A bin holds binFrames frames except the last.
    // Before the summary is shared only.
    void appendBin(float lo, float hi, double sumSquares, const double *bandSumSquares, uint32_t frames);
    void setTotalFrames(int64_t frames) { totalFrames_ = frames; }
    void markComplete() { complete_ = true; }

private:
    struct Level {
        uint64_t binFrames = 0;
        size_t count = 0;
        std::vector<_Float16> lo;
        std::vector<_Float16> hi;
        // The loudest windows and the archive read the sums. The tent reads
        // the bands' at every level.
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
    void reserve(Level &level, size_t bins) const;
    void derive(bool final) const;
    void reduceGroups(Level &up, const Level &below, size_t groups, size_t count) const;
    std::unique_ptr<Summary> snapshot() const;
    void uniteBins(size_t b0, size_t b1, Column &into) const;
    double binEnd(const Level &level, size_t bin) const;
    double binWidth(const Level &level, size_t bin) const { return binEnd(level, bin) - double(bin * level.binFrames); }

    bool bands_;
    double sampleRate_;
    int64_t frames_ = 0;
    int64_t totalFrames_ = 0;
    bool complete_ = false;
    Level base_;

    // The pyramid and the loudest windows, derived as bins arrive by a
    // builder, whole by a decode, or else on first read, and kept: a shared
    // summary never changes. base_.loudest holds the bins whose loudest
    // windows are derived.
    mutable std::mutex lazyLock_;
    mutable std::atomic<bool> pyramidBuilt_{false};
    mutable std::vector<Level> pyramid_;
    // The loudest window's sums, slid a bin at a time over [start, end).
    mutable struct {
        size_t start = 0, end = 0;
        double frames = 0, squares = 0;
        std::array<double, kBandCount> bandSquares = {};
    } window_;
    // Running sums per level, for the tent: per bin edge the frames' and
    // bands' first and second running sums. An entry is never replaced, so a
    // reader holding one is safe while another builds a second.
    mutable std::vector<std::pair<size_t, std::shared_ptr<const std::vector<double>>>> tentSums_;
    mutable Detail detail_;
};

// Builds a summary from a decode's mono mix, in order: its peaks, its energy
// and its bands.
class BandSplit;
class SummaryBuilder {
public:
    SummaryBuilder(bool bands, int64_t expectedFrames, double sampleRate);
    ~SummaryBuilder();

    void append(const float *mono, size_t frames);
    void setExpectedFrames(int64_t frames) { summary_->setTotalFrames(frames); }
    // The bins so far at the finest level of at most kSnapshotBins, for a
    // streaming load's progressive delivery.
    std::unique_ptr<Summary> snapshot() const { return summary_->snapshot(); }
    // Flushes the partial bin. A complete summary spans exactly what was read.
    std::unique_ptr<Summary> finish(bool complete);

private:
    void flushBin();

    std::unique_ptr<Summary> summary_;
    std::unique_ptr<BandSplit> split_;
    uint32_t binFill_ = 0;
    float lo_ = 0;
    float hi_ = 0;
    double sumSquares_ = 0;
    std::array<double, kBandCount> bandSumSquares_ = {0, 0, 0};
};

}  // namespace wavecore
