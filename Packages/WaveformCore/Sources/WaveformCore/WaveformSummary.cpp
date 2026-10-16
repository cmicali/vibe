//
//  WaveformSummary.cpp
//  WaveformCore
//

#include "WaveformSummary.hpp"
#include "WaveformBandSplit.hpp"

#include <Accelerate/Accelerate.h>
#include <compression.h>

#include <algorithm>
#include <cfloat>
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

void Summary::buildPyramid() const {
    std::lock_guard<std::mutex> lock(lazyLock_);
    if (pyramidBuilt_.load(std::memory_order_relaxed)) {
        return;
    }
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
        if (bands_) {
            next.bandSumSquares.resize(next.count * kBandCount);
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
            for (size_t j = j0; j < j1; j++) {
                sum += below.sumSquares[j];
            }
            next.sumSquares[i] = sum;
            for (size_t b = 0; bands_ && b < kBandCount; b++) {
                float band = 0;
                for (size_t j = j0; j < j1; j++) {
                    band += below.bandSumSquares[j * kBandCount + b];
                }
                next.bandSumSquares[i * kBandCount + b] = band;
            }
        }
        // The level below may move as this one is appended: build into a
        // local first.
        levels.push_back(std::move(next));
    }
    pyramid_ = std::move(levels);
    pyramidBuilt_.store(true, std::memory_order_release);
}

// The union of one bin's channels, or one channel's, into into.lo and hi.
// into starts at +inf and -inf.
static inline void UnionBin(const std::array<std::vector<_Float16>, kMaxChannels> &lo,
                            const std::array<std::vector<_Float16>, kMaxChannels> &hi,
                            uint32_t channels, size_t bin, int channel, Column &into) {
    uint32_t c0 = channel >= 0 ? uint32_t(channel) : 0;
    uint32_t c1 = channel >= 0 ? c0 + 1 : channels;
    for (uint32_t c = c0; c < c1 && c < channels; c++) {
        into.lo = std::fmin(into.lo, float(lo[c][bin]));
        into.hi = std::fmax(into.hi, float(hi[c][bin]));
    }
}

void Summary::accumulate(size_t levelIndex, double first, double last, int channel, bool extremes,
                         Column &into) const {
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
            if (extremes) {
                UnionBin(L.lo, L.hi, channels_, i, channel, into);
            }
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
        accumulate(levelIndex - 1, first, last, channel, extremes, into);
        return;
    }
    accumulate(levelIndex - 1, first, double(i0) * bf, channel, extremes, into);
    for (size_t i = i0; i < i1; i++) {
        if (extremes) {
            UnionBin(L.lo, L.hi, channels_, i, channel, into);
        }
        into.sumSquares += L.sumSquares[i];
        for (size_t b = 0; bands_ && b < kBandCount; b++) {
            into.bandSumSquares[b] += L.bandSumSquares[i * kBandCount + b];
        }
        into.frames += binEnd(L, i) - double(i) * bf;
    }
    accumulate(levelIndex - 1, double(i1) * bf, last, channel, extremes, into);
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
    accumulate(start, first, last, channel, true, result);
    if (!(result.lo <= result.hi)) {
        result.lo = result.hi = 0;
    }
    return result;
}

void Summary::columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out, int channel) const {
    for (size_t i = 0; i < count; i++) {
        double k = double(firstIndex + int64_t(i));
        out[i] = column(k * framesPerColumn, (k + 1) * framesPerColumn, channel);
    }
}

// Sums alone, over frames clipped to the summary: the cells of the windowed
// reads.
static inline void SumsOnly(const Summary &summary, double first, double last, Column &into) {
    Column part = summary.column(first, last);
    into.sumSquares = part.sumSquares;
    into.frames = part.frames;
    into.bandSumSquares = part.bandSumSquares;
}

void Summary::meanSquares(double framesPerColumn, int64_t firstIndex, size_t count, float reach,
                          float *mix, float *bands) const {
    bool wantsBands = bands && bands_;
    if (bands && !wantsBands) {
        std::fill(bands, bands + count * kBandCount, 0.0f);
    }
    if (count == 0 || !(mix || wantsBands)) {
        return;
    }
    // Cells a quarter column long, and a column-long window at every cell: a
    // column's own, and the two either side that the reach compares it with.
    // The half column either side comes from the summary itself, so a
    // window's edge columns read what a whole-track read would.
    bool slides = reach > 0;
    size_t cellsPerColumn = slides ? 4 : 1, padding = cellsPerColumn / 2;
    size_t cells = count * cellsPerColumn + 2 * padding;
    double cellFrames = framesPerColumn / double(cellsPerColumn);
    double origin = double(firstIndex) * framesPerColumn - double(padding) * cellFrames;
    // The running sums at every cell edge, so a window is two lookups.
    std::vector<double> frames(cells + 1, 0), squares(cells + 1, 0), bandSquares(wantsBands ? (cells + 1) * kBandCount : 0, 0);
    for (size_t j = 0; j < cells; j++) {
        Column cell;
        SumsOnly(*this, origin + double(j) * cellFrames, origin + double(j + 1) * cellFrames, cell);
        frames[j + 1] = frames[j] + cell.frames;
        squares[j + 1] = squares[j] + cell.sumSquares;
        for (size_t b = 0; wantsBands && b < kBandCount; b++) {
            bandSquares[(j + 1) * kBandCount + b] = bandSquares[j * kBandCount + b] + cell.bandSumSquares[b];
        }
    }
    // A window no frame reaches divides by the least float, which is silence.
    auto mean = [&](const std::vector<double> &plane, size_t stride, size_t offset, size_t window) {
        size_t a = window, b = window + cellsPerColumn;
        double covered = std::max(double(FLT_MIN), frames[b] - frames[a]);
        return float((plane[b * stride + offset] - plane[a * stride + offset]) / covered);
    };
    auto fill = [&](const std::vector<double> &plane, size_t stride, size_t offset, float *out, size_t outStride) {
        for (size_t i = 0; i < count; i++) {
            size_t first = i * cellsPerColumn;
            if (!slides) {
                out[i * outStride] = mean(plane, stride, offset, first);
                continue;
            }
            // The five around a column start at its first cell's index, its
            // own in the middle.
            float own = mean(plane, stride, offset, first + 2);
            float loudest = own;
            for (size_t w = 0; w < 5; w++) {
                loudest = std::fmax(loudest, mean(plane, stride, offset, first + w));
            }
            out[i * outStride] = own + reach * (loudest - own);
        }
    };
    if (mix) {
        fill(squares, 1, 0, mix, 1);
    }
    for (size_t b = 0; wantsBands && b < kBandCount; b++) {
        fill(bandSquares, kBandCount, b, bands + b, kBandCount);
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
                    double value = p == kFramesPlane ? binEnd(L, c) - double(c) * double(L.binFrames)
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

void Summary::loudestMeanSquares(size_t columns, float reach, float *mix, float *bands) const {
    {
        std::lock_guard<std::mutex> lock(lazyLock_);
        for (const Loudest &kept : loudest_) {
            if (kept.columns == columns && kept.reach == reach) {
                if (mix) *mix = kept.mix;
                if (bands) std::copy(kept.bands.begin(), kept.bands.end(), bands);
                return;
            }
        }
    }
    Loudest found = {columns, reach, 0, {0, 0, 0}};
    if (columns > 0 && totalFrames() > 0) {
        std::vector<float> perColumn(columns), perBand(columns * kBandCount);
        meanSquares(double(totalFrames()) / double(columns), 0, columns, reach, perColumn.data(),
                    bands_ ? perBand.data() : nullptr);
        vDSP_maxv(perColumn.data(), 1, &found.mix, columns);
        for (size_t b = 0; bands_ && b < kBandCount; b++) {
            vDSP_maxv(perBand.data() + b, kBandCount, &found.bands[b], columns);
        }
    }
    {
        std::lock_guard<std::mutex> lock(lazyLock_);
        loudest_.push_back(found);
    }
    if (mix) *mix = found.mix;
    if (bands) std::copy(found.bands.begin(), found.bands.end(), bands);
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
        double frames = binEnd(base_, i) - double(i) * double(binFrames_);
        *out++ = (_Float16)(frames > 0 ? base_.sumSquares[i] / frames : 0);
    }
    for (size_t b = 0; bands_ && b < kBandCount; b++) {
        for (size_t i = 0; i < n; i++) {
            double frames = binEnd(base_, i) - double(i) * double(binFrames_);
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
    return summary;
}

#pragma mark - Builder

SummaryBuilder::SummaryBuilder(uint32_t inputChannels, uint32_t storedChannels, bool bands, int64_t expectedFrames,
                               double sampleRate)
        : inputChannels_(std::max<uint32_t>(1, inputChannels)),
          channels_(inputChannels == 2 && storedChannels == 2 ? 2 : 1),
          binFrames_(BinFramesForLength(expectedFrames)) {
    summary_ = std::make_unique<Summary>(binFrames_, channels_, bands, sampleRate);
    summary_->setTotalFrames(expectedFrames);
    if (bands) {
        split_ = std::make_unique<BandSplit>(sampleRate);
    }
}

SummaryBuilder::~SummaryBuilder() = default;

void SummaryBuilder::append(const float *interleaved, const float *mono, size_t frames) {
    size_t offset = 0;
    while (offset < frames) {
        size_t take = std::min<size_t>(frames - offset, binFrames_ - binFill_);
        for (uint32_t c = 0; c < channels_; c++) {
            // One stored channel is the mix; two are the file's own.
            const float *source = channels_ == 1 ? mono + offset : interleaved + offset * inputChannels_ + c;
            vDSP_Stride stride = channels_ == 1 ? 1 : vDSP_Stride(inputChannels_);
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
        frames_ += int64_t(take);
        offset += take;
        if (binFill_ == binFrames_) {
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
    return std::move(summary_);
}

}  // namespace wavecore
