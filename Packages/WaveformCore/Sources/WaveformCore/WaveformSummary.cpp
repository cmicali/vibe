//
//  WaveformSummary.cpp
//  WaveformCore
//

#include "WaveformSummary.hpp"
#include "WaveformBandSplit.hpp"

#include <Accelerate/Accelerate.h>
#include <compression.h>

#include <algorithm>
#include <cstring>
#include <limits>

namespace wavecore {

// Each pyramid level's bins hold this many of the level below.
static constexpr size_t kFanout = 4;

uint32_t BinFramesForLength(int64_t frames) {
    uint32_t bin = kBaseBinFrames;
    while (bin > 1 && frames > 0 && frames / bin < kMinimumBins) {
        bin >>= 1;
    }
    return bin;
}

Summary::Summary(uint32_t binFrames, uint32_t channels, bool bands, double sampleRate)
        : binFrames_(std::max<uint32_t>(1, binFrames)),
          channels_(std::clamp<uint32_t>(channels, 1, kMaxChannels)),
          bands_(bands),
          sampleRate_(sampleRate) {
    base_.binFrames = binFrames_;
}

double Summary::decodedFraction() const {
    int64_t total = totalFrames();
    if (complete_ || total <= 0) {
        return 1;
    }
    return std::min(1.0, double(frames_) / double(total));
}

void Summary::appendBin(const float *lo, const float *hi, double sumSquares, const double *bandSumSquares,
                        uint32_t frames) {
    for (uint32_t c = 0; c < channels_; c++) {
        base_.lo[c].push_back((_Float16)lo[c]);
        base_.hi[c].push_back((_Float16)hi[c]);
    }
    base_.sumSquares.push_back(float(sumSquares));
    if (bands_) {
        for (size_t b = 0; b < kBandCount; b++) {
            base_.bandSumSquares.push_back(bandSumSquares ? float(bandSumSquares[b]) : 0.0f);
        }
    }
    base_.count++;
    frames_ += frames;
}

double Summary::binEnd(const Level &level, size_t bin) const {
    return std::min(double(bin + 1) * double(level.binFrames), double(frames_));
}

size_t Summary::levelCount() const {
    if (!pyramidBuilt_.load(std::memory_order_acquire)) {
        buildPyramid();
    }
    return 1 + pyramid_.size();
}

const Summary::Level &Summary::level(size_t index) const {
    return index == 0 ? base_ : pyramid_[index - 1];
}

// Each bin's loudest window: the RMS of the kTransientSeconds centred on it,
// clipped to the frames held, so a streaming load's front is not dragged
// toward the silence past it. lazyLock_ held.
void Summary::buildLoudest() const {
    size_t n = base_.count;
    size_t window = size_t(std::max(1.0, std::round(kTransientSeconds * sampleRate_ / double(binFrames_))));
    std::vector<double> frames(n + 1, 0), squares(n + 1, 0), bandSquares(bands_ ? (n + 1) * kBandCount : 0, 0);
    for (size_t i = 0; i < n; i++) {
        frames[i + 1] = frames[i] + binWidth(base_, i);
        squares[i + 1] = squares[i] + base_.sumSquares[i];
        for (size_t b = 0; bands_ && b < kBandCount; b++) {
            bandSquares[(i + 1) * kBandCount + b] = bandSquares[i * kBandCount + b] + base_.bandSumSquares[i * kBandCount + b];
        }
    }
    base_.loudest.resize(n);
    base_.bandLoudest.resize(bands_ ? n * kBandCount : 0);
    for (size_t i = 0; i < n; i++) {
        size_t start = i >= window / 2 ? i - window / 2 : 0, end = std::min(n, start + window);
        double covered = frames[end] - frames[start];
        auto rms = [&](double sum) { return _Float16(covered > 0 ? std::sqrt(std::max(0.0, sum) / covered) : 0.0); };
        base_.loudest[i] = rms(squares[end] - squares[start]);
        for (size_t b = 0; bands_ && b < kBandCount; b++) {
            base_.bandLoudest[i * kBandCount + b] =
                    rms(bandSquares[end * kBandCount + b] - bandSquares[start * kBandCount + b]);
        }
    }
}

void Summary::buildPyramid() const {
    std::lock_guard<std::mutex> lock(lazyLock_);
    if (pyramidBuilt_.load(std::memory_order_relaxed)) {
        return;
    }
    buildLoudest();
    std::vector<Level> levels;
    while ((levels.empty() ? base_.count : levels.back().count) > kFanout) {
        const Level &below = levels.empty() ? base_ : levels.back();
        Level next;
        next.binFrames = below.binFrames * kFanout;
        next.count = (below.count + kFanout - 1) / kFanout;
        for (uint32_t c = 0; c < channels_; c++) {
            next.lo[c].resize(next.count);
            next.hi[c].resize(next.count);
        }
        next.sumSquares.resize(next.count);
        next.loudest.resize(next.count);
        if (bands_) {
            next.bandSumSquares.resize(next.count * kBandCount);
            next.bandLoudest.resize(next.count * kBandCount);
        }
        for (size_t i = 0; i < next.count; i++) {
            size_t j0 = i * kFanout, j1 = std::min(below.count, j0 + kFanout);
            for (uint32_t c = 0; c < channels_; c++) {
                _Float16 lo = below.lo[c][j0], hi = below.hi[c][j0];
                for (size_t j = j0 + 1; j < j1; j++) {
                    lo = std::min(lo, below.lo[c][j]);
                    hi = std::max(hi, below.hi[c][j]);
                }
                next.lo[c][i] = lo;
                next.hi[c][i] = hi;
            }
            float sum = 0;
            _Float16 loudest = 0;
            for (size_t j = j0; j < j1; j++) {
                sum += below.sumSquares[j];
                loudest = std::max(loudest, below.loudest[j]);
            }
            next.sumSquares[i] = sum;
            next.loudest[i] = loudest;
            for (size_t b = 0; bands_ && b < kBandCount; b++) {
                float band = 0;
                _Float16 bandLoudest = 0;
                for (size_t j = j0; j < j1; j++) {
                    band += below.bandSumSquares[j * kBandCount + b];
                    bandLoudest = std::max(bandLoudest, below.bandLoudest[j * kBandCount + b]);
                }
                next.bandSumSquares[i * kBandCount + b] = band;
                next.bandLoudest[i * kBandCount + b] = bandLoudest;
            }
        }
        // The level below may move as this one is appended: build into a
        // local first.
        levels.push_back(std::move(next));
    }
    pyramid_ = std::move(levels);
    pyramidBuilt_.store(true, std::memory_order_release);
}

// One bin's unions into into: its channels' extremes, or one channel's, and
// its loudest windows. into starts at +inf and -inf.
static inline void UnionBin(const std::array<std::vector<_Float16>, kMaxChannels> &lo,
                            const std::array<std::vector<_Float16>, kMaxChannels> &hi,
                            const std::vector<_Float16> &loudest, const std::vector<_Float16> &bandLoudest,
                            uint32_t channels, size_t bin, int channel, Column &into) {
    uint32_t c0 = channel >= 0 ? uint32_t(channel) : 0;
    uint32_t c1 = channel >= 0 ? c0 + 1 : channels;
    for (uint32_t c = c0; c < c1 && c < channels; c++) {
        into.lo = std::fmin(into.lo, float(lo[c][bin]));
        into.hi = std::fmax(into.hi, float(hi[c][bin]));
    }
    into.loudest = std::fmax(into.loudest, float(loudest[bin]));
    for (size_t b = 0; b < kBandCount && !bandLoudest.empty(); b++) {
        into.bandLoudest[b] = std::fmax(into.bandLoudest[b], float(bandLoudest[bin * kBandCount + b]));
    }
}

void Summary::accumulate(size_t levelIndex, double first, double last, int channel, Column &into) const {
    if (last <= first) {
        return;
    }
    const Level &L = level(levelIndex);
    double bf = double(L.binFrames);
    if (levelIndex == 0) {
        size_t i0 = size_t(std::floor(first / bf));
        size_t i1 = std::min(L.count, size_t(std::ceil(last / bf)));
        for (size_t i = i0; i < i1; i++) {
            double start = double(i) * bf, end = binEnd(L, i);
            double overlap = std::min(last, end) - std::max(first, start);
            if (overlap <= 0 || end <= start) {
                continue;
            }
            UnionBin(L.lo, L.hi, L.loudest, L.bandLoudest, channels_, i, channel, into);
            double share = overlap / (end - start);
            into.sumSquares += share * L.sumSquares[i];
            for (size_t b = 0; bands_ && b < kBandCount; b++) {
                into.bandSumSquares[b] += share * L.bandSumSquares[i * kBandCount + b];
            }
            into.frames += overlap;
        }
        return;
    }
    size_t i0 = size_t(std::ceil(first / bf));
    size_t i1 = std::min(L.count, size_t(std::floor(last / bf)));
    if (i1 <= i0) {
        accumulate(levelIndex - 1, first, last, channel, into);
        return;
    }
    accumulate(levelIndex - 1, first, double(i0) * bf, channel, into);
    for (size_t i = i0; i < i1; i++) {
        UnionBin(L.lo, L.hi, L.loudest, L.bandLoudest, channels_, i, channel, into);
        into.sumSquares += L.sumSquares[i];
        for (size_t b = 0; bands_ && b < kBandCount; b++) {
            into.bandSumSquares[b] += L.bandSumSquares[i * kBandCount + b];
        }
        into.frames += binWidth(L, i);
    }
    accumulate(levelIndex - 1, double(i1) * bf, last, channel, into);
}

Column Summary::column(double first, double last, int channel) const {
    Column result;
    first = std::max(0.0, first);
    last = std::min(double(frames_), last);
    if (!(last > first) || base_.count == 0) {
        return result;
    }
    size_t levels = levelCount();
    size_t start = 0;
    while (start + 1 < levels && double(level(start + 1).binFrames) * kBinsPerColumn <= last - first) {
        start++;
    }
    result.lo = INFINITY;
    result.hi = -INFINITY;
    accumulate(start, first, last, channel, result);
    if (!(result.lo <= result.hi)) {
        result.lo = result.hi = 0;
    }
    return result;
}

void Detail::insertBlock(int64_t block, std::vector<float> samples) {
    auto held = std::make_shared<const std::vector<float>>(std::move(samples));
    std::lock_guard<std::mutex> lock(lock_);
    blocks_.erase(std::remove_if(blocks_.begin(), blocks_.end(),
                                 [&](const auto &entry) { return entry.first == block; }),
                  blocks_.end());
    blocks_.emplace_back(block, std::move(held));
    if (blocks_.size() > kMaxBlocks) {
        blocks_.erase(blocks_.begin());
    }
    lacked_.erase(std::remove(lacked_.begin(), lacked_.end(), block), lacked_.end());
    inserts_++;
}

bool Detail::hasBlock(int64_t block) const {
    std::lock_guard<std::mutex> lock(lock_);
    return std::any_of(blocks_.begin(), blocks_.end(), [&](const auto &entry) { return entry.first == block; });
}

uint64_t Detail::insertCount() const {
    std::lock_guard<std::mutex> lock(lock_);
    return inserts_;
}

std::vector<int64_t> Detail::takeLackedBlocks() {
    std::lock_guard<std::mutex> lock(lock_);
    return std::exchange(lacked_, {});
}

bool Detail::columns(double framesPerColumn, int64_t firstIndex, size_t count, int64_t frames, Column *out) const {
    if (count == 0 || frames <= 0 || !(framesPerColumn > 0)) {
        return count == 0;
    }
    // The samples the line runs through, one past each end of the frames.
    double first = std::max(0.0, double(firstIndex) * framesPerColumn);
    double last = std::min(double(frames), double(firstIndex + int64_t(count)) * framesPerColumn);
    int64_t s0 = std::clamp(int64_t(std::floor(first - 0.5)), int64_t(0), frames - 1);
    int64_t s1 = std::clamp(int64_t(std::ceil(last - 0.5)), s0, frames - 1);
    int64_t b0 = s0 / kBlockFrames, b1 = s1 / kBlockFrames;
    if (size_t(b1 - b0 + 1) > kMaxReadBlocks) {
        return false;
    }
    std::vector<std::shared_ptr<const std::vector<float>>> held(size_t(b1 - b0 + 1));
    {
        std::lock_guard<std::mutex> lock(lock_);
        for (const auto &entry : blocks_) {
            if (entry.first >= b0 && entry.first <= b1) {
                held[size_t(entry.first - b0)] = entry.second;
            }
        }
        std::vector<int64_t> missing;
        for (int64_t b = b0; b <= b1; b++) {
            if (!held[size_t(b - b0)]) {
                missing.push_back(b);
            }
        }
        if (!missing.empty()) {
            lacked_ = std::move(missing);
            return false;
        }
    }
    // Samples [s0, s1] in one run. A block short of its frames ends the
    // stream, its last sample held to the end.
    std::vector<float> run(size_t(s1 - s0 + 1));
    for (int64_t b = b0; b <= b1; b++) {
        const std::vector<float> &block = *held[size_t(b - b0)];
        int64_t start = b * kBlockFrames;
        int64_t from = std::max(s0, start), to = std::min(s1 + 1, start + kBlockFrames);
        size_t at = size_t(from - start), end = std::min(size_t(to - start), block.size());
        float *dest = run.data() + (from - s0);
        size_t copied = end > at ? end - at : 0;
        std::copy_n(block.begin() + ptrdiff_t(std::min(at, block.size())), copied, dest);
        std::fill(dest + copied, dest + (to - from), block.empty() ? 0.0f : block.back());
    }
    auto sample = [&](int64_t i) { return run[size_t(std::clamp(i, s0, s1) - s0)]; };
    auto line = [&](double frame) -> float {
        double u = frame - 0.5;
        double left = std::floor(u);
        float a = sample(int64_t(left)), b = sample(int64_t(left) + 1);
        return a + (b - a) * float(u - left);
    };
    for (size_t c = 0; c < count; c++) {
        Column &column = out[c];
        column = Column();
        double a = std::max(0.0, double(firstIndex + int64_t(c)) * framesPerColumn);
        double b = std::min(double(frames), double(firstIndex + int64_t(c) + 1) * framesPerColumn);
        if (!(b > a)) {
            continue;
        }
        float ends[2] = {line(a), line(b)};
        column.lo = std::min(ends[0], ends[1]);
        column.hi = std::max(ends[0], ends[1]);
        // The samples whose centers the column holds.
        int64_t c0 = int64_t(std::ceil(a - 0.5)), c1 = int64_t(std::ceil(b - 0.5));
        if (c1 > c0) {
            float lo, hi;
            vDSP_minv(&run[size_t(c0 - s0)], 1, &lo, vDSP_Length(c1 - c0));
            vDSP_maxv(&run[size_t(c0 - s0)], 1, &hi, vDSP_Length(c1 - c0));
            column.lo = std::min(column.lo, lo);
            column.hi = std::max(column.hi, hi);
        }
        // Each frame's square by its part in the column: the two ends by
        // hand, every frame between whole.
        int64_t i0 = int64_t(std::floor(a)), i1 = int64_t(std::ceil(b));
        auto square = [&](int64_t i) { return double(sample(i)) * double(sample(i)); };
        if (i1 - i0 == 1) {
            column.sumSquares = square(i0) * (b - a);
        } else {
            column.sumSquares = square(i0) * (double(i0 + 1) - a) + square(i1 - 1) * (b - double(i1 - 1));
            if (i1 - i0 > 2) {
                float between;
                vDSP_svesq(&run[size_t(i0 + 1 - s0)], 1, &between, vDSP_Length(i1 - i0 - 2));
                column.sumSquares += between;
            }
        }
        column.frames = b - a;
        column.loudest = float(std::sqrt(column.sumSquares / column.frames));
    }
    return true;
}

void Summary::columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out, int channel) const {
    if (framesPerColumn < double(binFrames_) && (channel == kAllChannels || channels_ == 1) &&
        detail_.columns(framesPerColumn, firstIndex, count, frames_, out)) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        double k = double(firstIndex + int64_t(i));
        out[i] = column(k * framesPerColumn, (k + 1) * framesPerColumn, channel);
    }
}

// A tent's integral is the second difference of a double running sum: with
// F1 the running sum and F2 the running sum of F1, a tent of half-base h
// about c integrates to (F2(c + h) - 2 F2(c) + F2(c - h)) / h. So a column
// costs three lookups a plane whatever the tent's width. Exact, because a
// bin is constant inside. Past the ends F1 holds, so the tent is clipped as
// silence would clip it. The sums are kept at the coarsest level a sixteenth
// of the half-base or finer.
void Summary::tentBandMeanSquares(double framesPerColumn, int64_t firstIndex, size_t count, double halfWidth,
                                  float *bands) const {
    std::fill(bands, bands + count * kBandCount, 0.0f);
    if (!bands_ || count == 0 || base_.count == 0 || !(halfWidth > 0)) {
        return;
    }
    enum { kFramesPlane, kBandsPlane, kPlanes = kBandsPlane + kBandCount, kStride = 2 * kPlanes };
    size_t levels = levelCount();
    size_t chosen = 0;
    while (chosen + 1 < levels && double(level(chosen + 1).binFrames) * 16 <= halfWidth) {
        chosen++;
    }
    const Level &L = level(chosen);
    std::shared_ptr<const std::vector<double>> sums;
    {
        std::lock_guard<std::mutex> lock(lazyLock_);
        for (const auto &entry : tentSums_) {
            if (entry.first == chosen) {
                sums = entry.second;
            }
        }
        if (!sums) {
            auto built = std::make_shared<std::vector<double>>((L.count + 1) * kStride, 0.0);
            for (size_t c = 0; c < L.count; c++) {
                const double *at = &(*built)[c * kStride];
                double *next = &(*built)[(c + 1) * kStride];
                for (size_t p = 0; p < kPlanes; p++) {
                    double value = p == kFramesPlane ? binWidth(L, c)
                                                     : double(L.bandSumSquares[c * kBandCount + p - kBandsPlane]);
                    next[p] = at[p] + value;
                    next[kPlanes + p] = at[kPlanes + p] + at[p] + value / 2;
                }
            }
            tentSums_.emplace_back(chosen, built);
            sums = built;
        }
    }
    const double *table = sums->data();
    double bf = double(L.binFrames);
    size_t n = L.count;
    auto F2 = [&](double x, double *out) {
        if (x <= 0) {
            std::fill(out, out + kPlanes, 0.0);
            return;
        }
        size_t c = x >= double(n) ? n : size_t(x);
        double t = x - double(c);
        const double *at = table + c * kStride;
        // Past the last edge nothing is added, so F2 continues straight.
        const double *next = c < n ? at + kStride : at;
        for (size_t p = 0; p < kPlanes; p++) {
            out[p] = at[kPlanes + p] + at[p] * t + (next[p] - at[p]) * t * t / 2;
        }
    };
    double h = halfWidth / bf;
    for (size_t i = 0; i < count; i++) {
        double centre = (double(firstIndex + int64_t(i)) + 0.5) * framesPerColumn / bf;
        double left[kPlanes], middle[kPlanes], right[kPlanes];
        F2(centre - h, left);
        F2(centre, middle);
        F2(centre + h, right);
        double frames = right[kFramesPlane] - 2 * middle[kFramesPlane] + left[kFramesPlane];
        for (size_t b = 0; b < kBandCount; b++) {
            size_t p = kBandsPlane + b;
            bands[i * kBandCount + b] = frames > 0 ? float((right[p] - 2 * middle[p] + left[p]) / frames) : 0;
        }
    }
}

std::unique_ptr<Summary> Summary::copy() const {
    auto copy = std::make_unique<Summary>(binFrames_, channels_, bands_, sampleRate_);
    copy->base_.lo = base_.lo;
    copy->base_.hi = base_.hi;
    copy->base_.sumSquares = base_.sumSquares;
    copy->base_.bandSumSquares = base_.bandSumSquares;
    copy->base_.count = base_.count;
    copy->frames_ = frames_;
    copy->totalFrames_ = totalFrames_;
    copy->complete_ = complete_;
    copy->buildPyramid();
    return copy;
}

#pragma mark - Archive

namespace {

// Little-endian, as every platform this runs on is.
struct ArchiveHeader {
    char magic[4];
    uint16_t version;
    uint16_t flags;
    uint32_t binFrames;
    uint32_t channels;
    uint64_t binCount;
    int64_t frames;
    int64_t totalFrames;
    double sampleRate;
    uint32_t payloadBytes;
    uint32_t rawBytes;
};
static_assert(sizeof(ArchiveHeader) == 56, "archive header layout");

// Before compression, each plane's values become the difference from the
// one before, as 16-bit patterns, so a smooth plane is mostly small numbers.
// Then every low byte comes before every high byte, since the high bytes
// (sign, exponent and the top of the mantissa) repeat. Measured on real
// tracks, the two make LZFSE's archive 5 to 13% smaller. Both are exact.
std::vector<uint8_t> Shuffle(const std::vector<_Float16> &values, size_t planeLength) {
    std::vector<uint8_t> out(values.size() * 2);
    for (size_t i = 0; planeLength > 0 && i < values.size(); i++) {
        uint16_t value, previous = 0;
        std::memcpy(&value, &values[i], 2);
        if (i % planeLength != 0) {
            std::memcpy(&previous, &values[i - 1], 2);
        }
        uint16_t delta = uint16_t(value - previous);
        out[i] = uint8_t(delta);
        out[values.size() + i] = uint8_t(delta >> 8);
    }
    return out;
}

std::vector<_Float16> Unshuffle(const std::vector<uint8_t> &bytes, size_t count, size_t planeLength) {
    std::vector<_Float16> values(count);
    uint16_t previous = 0;
    for (size_t i = 0; planeLength > 0 && i < count; i++) {
        uint16_t delta = uint16_t(bytes[i] | (bytes[count + i] << 8));
        uint16_t value = uint16_t((i % planeLength != 0 ? previous : 0) + delta);
        std::memcpy(&values[i], &value, 2);
        previous = value;
    }
    return values;
}

constexpr char kArchiveMagic[4] = {'W', 'F', 'S', 'M'};
constexpr uint16_t kArchiveVersion = 1;
enum : uint16_t { kFlagBands = 1, kFlagComplete = 2, kFlagCompressed = 4 };
// Far past any real file (a day at 192 kHz in 256-frame bins), so a corrupt
// count cannot ask for gigabytes.
constexpr uint64_t kMaxArchivedBins = uint64_t(1) << 27;

}  // namespace

std::vector<uint8_t> Summary::encode() const {
    size_t n = base_.count;
    size_t planes = 2 * channels_ + 1 + (bands_ ? kBandCount : 0);
    std::vector<_Float16> raw(planes * n);
    _Float16 *out = raw.data();
    for (uint32_t c = 0; c < channels_; c++) {
        std::copy(base_.lo[c].begin(), base_.lo[c].end(), out);
        out += n;
        std::copy(base_.hi[c].begin(), base_.hi[c].end(), out);
        out += n;
    }
    // Means, not sums: a long bin's sum would not fit a float16.
    for (size_t i = 0; i < n; i++) {
        double frames = binWidth(base_, i);
        *out++ = (_Float16)(frames > 0 ? base_.sumSquares[i] / frames : 0);
    }
    for (size_t b = 0; bands_ && b < kBandCount; b++) {
        for (size_t i = 0; i < n; i++) {
            double frames = binWidth(base_, i);
            *out++ = (_Float16)(frames > 0 ? base_.bandSumSquares[i * kBandCount + b] / frames : 0);
        }
    }
    size_t rawBytes = raw.size() * sizeof(_Float16);
    std::vector<uint8_t> shuffled = Shuffle(raw, n);
    std::vector<uint8_t> blob(sizeof(ArchiveHeader) + rawBytes + 4096);
    size_t payload = rawBytes == 0 ? 0
            : compression_encode_buffer(blob.data() + sizeof(ArchiveHeader), blob.size() - sizeof(ArchiveHeader),
                                        shuffled.data(), rawBytes, nullptr, COMPRESSION_LZFSE);
    bool compressed = payload > 0 && payload < rawBytes;
    if (!compressed) {
        payload = rawBytes;
        std::memcpy(blob.data() + sizeof(ArchiveHeader), shuffled.data(), rawBytes);
    }
    ArchiveHeader header = {};
    std::memcpy(header.magic, kArchiveMagic, 4);
    header.version = kArchiveVersion;
    header.flags = uint16_t((bands_ ? kFlagBands : 0) | (complete_ ? kFlagComplete : 0) |
                            (compressed ? kFlagCompressed : 0));
    header.binFrames = binFrames_;
    header.channels = channels_;
    header.binCount = n;
    header.frames = frames_;
    header.totalFrames = totalFrames_;
    header.sampleRate = sampleRate_;
    header.payloadBytes = uint32_t(payload);
    header.rawBytes = uint32_t(rawBytes);
    std::memcpy(blob.data(), &header, sizeof(header));
    blob.resize(sizeof(ArchiveHeader) + payload);
    return blob;
}

std::unique_ptr<Summary> Summary::decode(const void *bytes, size_t length) {
    if (!bytes || length < sizeof(ArchiveHeader)) {
        return nullptr;
    }
    // TRAP: an archive's bytes need not be aligned. Copy, never cast.
    ArchiveHeader header;
    std::memcpy(&header, bytes, sizeof(header));
    if (std::memcmp(header.magic, kArchiveMagic, 4) != 0 || header.version != kArchiveVersion) {
        return nullptr;
    }
    uint32_t bf = header.binFrames;
    bool powerOfTwo = bf > 0 && bf <= kBaseBinFrames && (bf & (bf - 1)) == 0;
    uint64_t n = header.binCount;
    if (!powerOfTwo || header.channels < 1 || header.channels > kMaxChannels || n > kMaxArchivedBins ||
        !std::isfinite(header.sampleRate) || header.sampleRate <= 0 || header.totalFrames < 0) {
        return nullptr;
    }
    // The frames must end inside the last bin.
    if (n == 0 ? header.frames != 0
               : (header.frames <= int64_t((n - 1) * bf) || header.frames > int64_t(n * bf))) {
        return nullptr;
    }
    bool bands = header.flags & kFlagBands;
    size_t planes = 2 * header.channels + 1 + (bands ? kBandCount : 0);
    size_t rawBytes = planes * n * sizeof(_Float16);
    if (header.rawBytes != rawBytes || header.payloadBytes != length - sizeof(ArchiveHeader)) {
        return nullptr;
    }
    std::vector<uint8_t> shuffled(rawBytes);
    const uint8_t *payload = static_cast<const uint8_t *>(bytes) + sizeof(ArchiveHeader);
    if (header.flags & kFlagCompressed) {
        size_t decoded = rawBytes == 0 ? 0
                : compression_decode_buffer(shuffled.data(), rawBytes, payload, header.payloadBytes, nullptr,
                                            COMPRESSION_LZFSE);
        if (decoded != rawBytes) {
            return nullptr;
        }
    } else if (header.payloadBytes == rawBytes) {
        std::memcpy(shuffled.data(), payload, rawBytes);
    } else {
        return nullptr;
    }
    std::vector<_Float16> raw = Unshuffle(shuffled, planes * n, n);
    for (_Float16 value : raw) {
        if (!std::isfinite(float(value))) {
            return nullptr;
        }
    }
    auto summary = std::make_unique<Summary>(bf, header.channels, bands, header.sampleRate);
    const _Float16 *in = raw.data();
    std::vector<float> lo(header.channels), hi(header.channels);
    std::vector<double> bandSums(kBandCount);
    for (uint64_t i = 0; i < n; i++) {
        for (uint32_t c = 0; c < header.channels; c++) {
            lo[c] = float(in[(2 * c) * n + i]);
            hi[c] = float(in[(2 * c + 1) * n + i]);
            if (lo[c] > hi[c]) {
                return nullptr;
            }
        }
        uint32_t frames = uint32_t(std::min<int64_t>(bf, header.frames - int64_t(i * bf)));
        float mean = float(in[2 * header.channels * n + i]);
        if (mean < 0) {
            return nullptr;
        }
        for (size_t b = 0; bands && b < kBandCount; b++) {
            float bandMean = float(in[(2 * header.channels + 1 + b) * n + i]);
            if (bandMean < 0) {
                return nullptr;
            }
            bandSums[b] = double(bandMean) * frames;
        }
        summary->appendBin(lo.data(), hi.data(), double(mean) * frames, bands ? bandSums.data() : nullptr, frames);
    }
    summary->totalFrames_ = header.totalFrames;
    summary->complete_ = header.flags & kFlagComplete;
    summary->buildPyramid();
    return summary;
}

#pragma mark - Builder

SummaryBuilder::SummaryBuilder(uint32_t inputChannels, uint32_t storedChannels, bool bands, int64_t expectedFrames,
                               double sampleRate)
        : summary_(std::make_unique<Summary>(BinFramesForLength(expectedFrames),
                                             inputChannels == 2 && storedChannels == 2 ? 2 : 1, bands, sampleRate)),
          inputChannels_(std::max<uint32_t>(1, inputChannels)) {
    summary_->setTotalFrames(expectedFrames);
    if (bands) {
        split_ = std::make_unique<BandSplit>(sampleRate);
    }
}

SummaryBuilder::~SummaryBuilder() = default;

void SummaryBuilder::append(const float *interleaved, const float *mono, size_t frames) {
    uint32_t binFrames = summary_->binFrames(), channels = summary_->channels();
    size_t offset = 0;
    while (offset < frames) {
        size_t take = std::min<size_t>(frames - offset, binFrames - binFill_);
        for (uint32_t c = 0; c < channels; c++) {
            // One stored channel is the mix; two are the file's own.
            const float *source = channels == 1 ? mono + offset : interleaved + offset * inputChannels_ + c;
            vDSP_Stride stride = channels == 1 ? 1 : vDSP_Stride(inputChannels_);
            float lo, hi;
            vDSP_minv(source, stride, &lo, take);
            vDSP_maxv(source, stride, &hi, take);
            // A corrupt file can decode NaN or Inf, which vDSP propagates:
            // NaN geometry in every view, persisted under the file's key.
            if (!std::isfinite(lo)) lo = 0;
            if (!std::isfinite(hi)) hi = 0;
            lo_[c] = binFill_ ? std::fmin(lo_[c], lo) : lo;
            hi_[c] = binFill_ ? std::fmax(hi_[c], hi) : hi;
        }
        float meanSquare;
        vDSP_measqv(mono + offset, 1, &meanSquare, take);
        if (std::isfinite(meanSquare)) {
            sumSquares_ += double(meanSquare) * double(take);
        }
        if (split_) {
            split_->addSumSquares(mono + offset, take, bandSumSquares_.data());
        }
        binFill_ += uint32_t(take);
        offset += take;
        if (binFill_ == binFrames) {
            flushBin();
        }
    }
}

void SummaryBuilder::flushBin() {
    summary_->appendBin(lo_.data(), hi_.data(), sumSquares_, bandSumSquares_.data(), binFill_);
    binFill_ = 0;
    sumSquares_ = 0;
    bandSumSquares_ = {0, 0, 0};
}

std::unique_ptr<Summary> SummaryBuilder::finish(bool complete) {
    if (binFill_ > 0) {
        flushBin();
    }
    if (complete) {
        summary_->markComplete();
    }
    summary_->buildPyramid();
    return std::move(summary_);
}

}  // namespace wavecore
