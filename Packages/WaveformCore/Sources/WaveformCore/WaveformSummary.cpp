//
//  WaveformSummary.cpp
//  WaveformCore
//

#include "WaveformSummary.hpp"
#include "WaveformBandSplit.hpp"

#include <Accelerate/Accelerate.h>
#include <compression.h>
#include <simd/simd.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <type_traits>

namespace wavecore {

// Each pyramid level's bins hold this many of the level below.
static constexpr size_t kFanout = 4;

uint32_t BinFramesForLength(int64_t frames) {
    uint32_t bin = kBaseBinFrames;
    while (bin > 1 && frames > 0 && frames / bin < kMinimumBins) {
        bin >>= 1;
    }
    while (frames / bin > kMaximumBins) {
        bin <<= 1;
    }
    return bin;
}

Summary::Summary(uint32_t binFrames, bool bands, double sampleRate) : bands_(bands), sampleRate_(sampleRate) {
    base_.binFrames = std::max<uint32_t>(1, binFrames);
}

void Summary::appendBin(float lo, float hi, double sumSquares, const double *bandSumSquares, uint32_t frames) {
    base_.lo.push_back((_Float16)lo);
    base_.hi.push_back((_Float16)hi);
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
// toward the silence past it. A window is whole once the bins half a window
// past its bin are in, and final takes each window as it stands. The sums
// slide a bin at a time, in the order a pass over the finished bins would
// add them.
//
// Each level then takes whole groups of kFanout bins below it, and final the
// last group however short. So a level holds only bins that will not change,
// each reduced as a pass over the finished bins would reduce it, and a
// builder's summary is identical to one built whole. That pass builds a
// level above each level of more than kFanout bins. A builder's own summary,
// or lazyLock_ held.
void Summary::derive(bool final) const {
    size_t n = base_.count;
    size_t window = size_t(std::max(1.0, std::round(kTransientSeconds * sampleRate_ / double(base_.binFrames))));
    size_t half = window / 2;
    // Bin i's window is [i - half, i - half + window), clamped at 0, and whole
    // once it ends within the bins held. A snapshot's bins arrive with their
    // loudest windows.
    size_t first = base_.loudest.size();
    size_t whole = final ? n : n >= window ? n - window + half + 1 : 0;
    if (whole > first) {
        base_.loudest.resize(whole);
        base_.bandLoudest.resize(bands_ ? whole * kBandCount : 0);
    }
    // In locals, so the compiler need not reload them for every bin.
    auto sums = window_;
    const float *squares = base_.sumSquares.data(), *bandSquares = base_.bandSumSquares.data();
    _Float16 *loudest = base_.loudest.data(), *bandLoudest = base_.bandLoudest.data();
    // Every bin but the last holds binFrames.
    double binFrames = double(base_.binFrames), lastWidth = n > 0 ? binWidth(base_, n - 1) : 0;
    // The mix and the bands are a vector's four lanes. Each lane adds,
    // divides and roots exactly as one scalar would, two lanes an instruction.
    simd_double4 total = {sums.squares, sums.bandSquares[0], sums.bandSquares[1], sums.bandSquares[2]};
    auto bin = [&](size_t index) {
        simd_double4 lanes = {squares[index], 0, 0, 0};
        if (bands_) {
            lanes[1] = bandSquares[index * kBandCount];
            lanes[2] = bandSquares[index * kBandCount + 1];
            lanes[3] = bandSquares[index * kBandCount + 2];
        }
        return lanes;
    };
    const simd_double4 zero = 0;
    for (size_t i = first; i < whole; i++) {
        size_t from = i >= half ? i - half : 0, to = std::min(n, from + window);
        for (; sums.end < to; sums.end++) {
            sums.frames += sums.end + 1 < n ? binFrames : lastWidth;
            total += bin(sums.end);
        }
        for (; sums.start < from; sums.start++) {
            sums.frames -= sums.start + 1 < n ? binFrames : lastWidth;
            total -= bin(sums.start);
        }
        // Each lane converts to float16 from double, never through float,
        // which would round twice.
        simd_double4 rms = sums.frames > 0 ? simd::sqrt(simd_max(total, zero) / sums.frames) : zero;
        loudest[i] = _Float16(rms[0]);
        if (bands_) {
            bandLoudest[i * kBandCount] = _Float16(rms[1]);
            bandLoudest[i * kBandCount + 1] = _Float16(rms[2]);
            bandLoudest[i * kBandCount + 2] = _Float16(rms[3]);
        }
    }
    sums.squares = total[0];
    sums.bandSquares = {total[1], total[2], total[3]};
    window_ = sums;
    for (size_t index = 1;; index++) {
        size_t below = index == 1 ? base_.loudest.size() : level(index - 1).count;
        if (final ? below <= kFanout : below < kFanout) {
            if (final) {
                pyramid_.resize(index - 1);
            }
            break;
        }
        if (pyramid_.size() < index) {
            pyramid_.emplace_back();
            pyramid_.back().binFrames = base_.binFrames << (2 * index);
            reserve(pyramid_.back(), (base_.sumSquares.capacity() >> (2 * index)) + 1);
        }
        const Level &from = level(index - 1);
        Level &up = pyramid_[index - 1];
        reduceGroups(up, from, final ? (below + kFanout - 1) / kFanout : below / kFanout, below);
    }
}

// below's bins in groups of kFanout, each a new bin of up, until up holds
// `groups`. The last group holds what remains of below's `count`. Each is
// reduced in order, as a pass over the finished bins would: the first bin,
// then each next one into it.
void Summary::reduceGroups(Level &up, const Level &below, size_t groups, size_t count) const {
    size_t at = up.count;
    if (groups <= at) {
        return;
    }
    // Whole groups take a constant count, so the compiler unrolls them with
    // no test per group. Then the short last group.
    size_t whole = std::max(at, std::min(groups, count / kFanout));
    auto forGroups = [&](auto body) {
        for (size_t g = at; g < whole; g++) body(g, std::integral_constant<size_t, kFanout>());
        for (size_t g = whole; g < groups; g++) body(g, count - g * kFanout);
    };
    auto extremes = [&](const std::vector<_Float16> &from, std::vector<_Float16> &to, auto pick) {
        to.resize(groups);
        const _Float16 *in = from.data();
        _Float16 *out = to.data();
        forGroups([&](size_t g, auto children) {
            const _Float16 *x = in + g * kFanout;
            _Float16 value = x[0];
            for (size_t j = 1; j < children; j++) value = pick(value, x[j]);
            out[g] = value;
        });
    };
    auto sums = [&](const std::vector<float> &from, std::vector<float> &to, size_t stride, size_t lane) {
        const float *in = from.data() + lane;
        float *out = to.data() + lane;
        forGroups([&](size_t g, auto children) {
            const float *x = in + g * kFanout * stride;
            float sum = 0;
            for (size_t j = 0; j < children; j++) sum += x[j * stride];
            out[g * stride] = sum;
        });
    };
    auto loudest = [&](const std::vector<_Float16> &from, std::vector<_Float16> &to, size_t stride, size_t lane) {
        const _Float16 *in = from.data() + lane;
        _Float16 *out = to.data() + lane;
        forGroups([&](size_t g, auto children) {
            const _Float16 *x = in + g * kFanout * stride;
            _Float16 value = 0;
            for (size_t j = 0; j < children; j++) value = std::max(value, x[j * stride]);
            out[g * stride] = value;
        });
    };
    extremes(below.lo, up.lo, [](_Float16 a, _Float16 b) { return std::min(a, b); });
    extremes(below.hi, up.hi, [](_Float16 a, _Float16 b) { return std::max(a, b); });
    up.sumSquares.resize(groups);
    up.loudest.resize(groups);
    sums(below.sumSquares, up.sumSquares, 1, 0);
    loudest(below.loudest, up.loudest, 1, 0);
    if (bands_) {
        up.bandSumSquares.resize(groups * kBandCount);
        up.bandLoudest.resize(groups * kBandCount);
        for (size_t b = 0; b < kBandCount; b++) {
            sums(below.bandSumSquares, up.bandSumSquares, kBandCount, b);
            loudest(below.bandLoudest, up.bandLoudest, kBandCount, b);
        }
    }
    up.count = groups;
}

// Room for bins in every plane of level, so a decode of known length copies
// none of them as they grow.
void Summary::reserve(Level &level, size_t bins) const {
    level.lo.reserve(bins);
    level.hi.reserve(bins);
    level.sumSquares.reserve(bins);
    level.loudest.reserve(bins);
    if (bands_) {
        level.bandSumSquares.reserve(bins * kBandCount);
        level.bandLoudest.reserve(bins * kBandCount);
    }
}

void Summary::buildPyramid() const {
    std::lock_guard<std::mutex> lock(lazyLock_);
    if (pyramidBuilt_.load(std::memory_order_relaxed)) {
        return;
    }
    derive(true);
    pyramidBuilt_.store(true, std::memory_order_release);
}

// The unions over base bins [b0, b1), through the pyramid: at each level the
// bins left at either end until both ends align with the level above.
// Unions do not depend on order, so any decomposition reads the same.
void Summary::uniteBins(size_t b0, size_t b1, Column &into) const {
    float lo = into.lo, hi = into.hi, loudest = into.loudest;
    std::array<float, kBandCount> bandLoudest = into.bandLoudest;
    static_assert(kFanout == 4, "a parent holds four bins");
    // The pyramid is built: the caller asked levelCount.
    size_t levels = 1 + pyramid_.size();
    bool bands = !base_.bandLoudest.empty();
    for (size_t index = 0; b0 < b1; index++) {
        const Level &L = level(index);
        // The planes' data, loaded once a level rather than once a bin.
        const _Float16 *los = L.lo.data(), *his = L.hi.data();
        const _Float16 *loudests = L.loudest.data(), *bandLoudests = L.bandLoudest.data();
        auto take = [&](size_t i) {
            lo = std::fmin(lo, float(los[i]));
            hi = std::fmax(hi, float(his[i]));
            loudest = std::fmax(loudest, float(loudests[i]));
            if (bands) {
                for (size_t b = 0; b < kBandCount; b++) {
                    bandLoudest[b] = std::fmax(bandLoudest[b], float(bandLoudests[i * kBandCount + b]));
                }
            }
        };
        if (index + 1 == levels) {
            for (size_t i = b0; i < b1; i++) take(i);
            break;
        }
        while (b0 < b1 && (b0 & 3) != 0) take(b0++);
        while (b0 < b1 && (b1 & 3) != 0) take(--b1);
        b0 >>= 2;
        b1 >>= 2;
    }
    into.lo = lo;
    into.hi = hi;
    into.loudest = loudest;
    into.bandLoudest = bandLoudest;
}

Column Summary::column(double first, double last) const {
    Column result;
    first = std::max(0.0, first);
    last = std::min(double(frames_), last);
    if (!(last > first) || base_.count == 0) {
        return result;
    }
    double bf = double(base_.binFrames);
    result.lo = INFINITY;
    result.hi = -INFINITY;
    levelCount();
    uniteBins(size_t(std::floor(first / bf)), std::min(base_.count, size_t(std::ceil(last / bf))), result);
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
    size_t blocks = size_t(b1 - b0 + 1);
    if (blocks > kMaxReadBlocks) {
        return false;
    }
    // Held for the read, so an insert that evicts one cannot free it here.
    std::array<std::shared_ptr<const std::vector<float>>, kMaxReadBlocks> held;
    {
        std::lock_guard<std::mutex> lock(lock_);
        for (const auto &entry : blocks_) {
            if (entry.first >= b0 && entry.first <= b1) {
                held[size_t(entry.first - b0)] = entry.second;
            }
        }
        if (std::any_of(held.begin(), held.begin() + ptrdiff_t(blocks), [](const auto &block) { return !block; })) {
            for (int64_t b = b0; b <= b1; b++) {
                if (!held[size_t(b - b0)] && std::find(lacked_.begin(), lacked_.end(), b) == lacked_.end()) {
                    lacked_.push_back(b);
                }
            }
            return false;
        }
    }
    // Samples [s0, s1] as one run: in place where one block holds them all,
    // else copied into this thread's scratch. A copy into a fresh run
    // allocated and zeroed up to 2 MB on every read of every pinch frame. A
    // block short of its frames ends the stream, its last sample held to the
    // end.
    const float *run;
    const std::vector<float> &only = *held[0];
    if (b0 == b1 && s1 - b0 * kBlockFrames < int64_t(only.size())) {
        run = only.data() + (s0 - b0 * kBlockFrames);
    } else {
        thread_local std::vector<float> scratch;
        if (scratch.size() < size_t(s1 - s0 + 1)) {
            scratch.resize(size_t(s1 - s0 + 1));
        }
        for (int64_t b = b0; b <= b1; b++) {
            const std::vector<float> &block = *held[size_t(b - b0)];
            int64_t start = b * kBlockFrames;
            int64_t from = std::max(s0, start), to = std::min(s1 + 1, start + kBlockFrames);
            size_t at = size_t(from - start), end = std::min(size_t(to - start), block.size());
            float *dest = scratch.data() + (from - s0);
            size_t copied = end > at ? end - at : 0;
            std::copy_n(block.begin() + ptrdiff_t(std::min(at, block.size())), copied, dest);
            std::fill(dest + copied, dest + (to - from), block.empty() ? 0.0f : block.back());
        }
        run = scratch.data();
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
        // Its level is its own RMS: each frame's square by its part in the
        // column, the two ends by hand and every frame between whole.
        int64_t i0 = int64_t(std::floor(a)), i1 = int64_t(std::ceil(b));
        auto square = [&](int64_t i) { return double(sample(i)) * double(sample(i)); };
        double squares;
        if (i1 - i0 == 1) {
            squares = square(i0) * (b - a);
        } else {
            squares = square(i0) * (double(i0 + 1) - a) + square(i1 - 1) * (b - double(i1 - 1));
            if (i1 - i0 > 2) {
                float between;
                vDSP_svesq(&run[size_t(i0 + 1 - s0)], 1, &between, vDSP_Length(i1 - i0 - 2));
                squares += between;
            }
        }
        column.loudest = float(std::sqrt(squares / (b - a)));
    }
    return true;
}

void Summary::columns(double framesPerColumn, int64_t firstIndex, size_t count, Column *out) const {
    auto bins = [&](size_t from, size_t to) {
        for (size_t i = from; i < to; i++) {
            double k = double(firstIndex + int64_t(i));
            out[i] = column(k * framesPerColumn, (k + 1) * framesPerColumn);
        }
    };
    double first = double(firstIndex) * framesPerColumn, last = double(firstIndex + int64_t(count)) * framesPerColumn;
    int64_t span = int64_t(std::floor(std::max(0.0, last) / Detail::kBlockFrames)) -
                   int64_t(std::floor(std::max(0.0, first) / Detail::kBlockFrames)) + 1;
    if (!(framesPerColumn < double(base_.binFrames)) || count == 0 || span > int64_t(Detail::kMaxReadBlocks)) {
        bins(0, count);
        return;
    }
    // A block at a time, so a block still loading draws its own columns from
    // the bins and leaves the rest on the samples. Read whole, one missing
    // block dropped every column to the bins, and the picture flashed each
    // time a scroll reached a block not yet in. Columns are grouped by the
    // blocks their samples need, as Detail::columns finds them, so only the
    // column across a block's edge needs both blocks.
    auto blocks = [&](size_t c) {
        double a = std::max(0.0, double(firstIndex + int64_t(c)) * framesPerColumn);
        double b = std::min(double(frames_), double(firstIndex + int64_t(c) + 1) * framesPerColumn);
        int64_t s0 = std::clamp(int64_t(std::floor(a - 0.5)), int64_t(0), std::max(frames_ - 1, int64_t(0)));
        int64_t s1 = std::clamp(int64_t(std::ceil(b - 0.5)), s0, std::max(frames_ - 1, s0));
        return std::make_pair(s0 / Detail::kBlockFrames, s1 / Detail::kBlockFrames);
    };
    for (size_t from = 0; from < count;) {
        auto need = blocks(from);
        size_t to = from + 1;
        while (to < count && blocks(to) == need) {
            to++;
        }
        if (!detail_.columns(framesPerColumn, firstIndex + int64_t(from), to - from, frames_, out + from)) {
            bins(from, to);
        }
        from = to;
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

// Copies the finest level of at most kSnapshotBins and its upper levels.
// The base keeps its unfinished loudest windows from the builder's sums.
// An upper level holds only whole groups. It trails the last appended bin
// by less than one of its bins and half a loudest window. That is at most
// a second of a stream hours long.
std::unique_ptr<Summary> Summary::snapshot() const {
    size_t index = 0;
    while (index < pyramid_.size() && level(index).count > kSnapshotBins) {
        index++;
    }
    const Level &from = level(index);
    size_t bins = from.count;
    auto copy = std::make_unique<Summary>(uint32_t(from.binFrames), bands_, sampleRate_);
    copy->base_ = from;
    // Whole groups are already derived. Only the streaming front needs
    // closing, and no copied level is finer than the bounded snapshot.
    copy->pyramid_.assign(pyramid_.begin() + ptrdiff_t(index), pyramid_.end());
    if (index == 0) {
        copy->frames_ = frames_;
        copy->window_ = window_;
    } else {
        copy->frames_ = std::min<int64_t>(frames_, int64_t(uint64_t(bins) * from.binFrames));
    }
    copy->totalFrames_ = totalFrames_;
    copy->buildPyramid();
    return copy;
}

#pragma mark - Archive

namespace {

// Little-endian, as every platform this runs on is. The planes' size follows
// from the bin count and the flags.
struct ArchiveHeader {
    char magic[4];
    uint16_t version;
    uint16_t flags;
    uint32_t binFrames;
    uint32_t payloadBytes;
    uint64_t binCount;
    int64_t frames;
    int64_t totalFrames;
    double sampleRate;
};
static_assert(sizeof(ArchiveHeader) == 48, "archive header layout");

// A value's low byte and its high byte go in separate streams. The low
// bytes, the bottom of the mantissa, are mostly noise, so they take LZ4,
// which gives up on noise quickly and still shrinks silence. The high bytes,
// the sign, the exponent and the top of the mantissa, repeat, so they take
// LZFSE. Measured on 95 real tracks against LZFSE over both halves after a
// delta filter, the archive is 2% smaller, encodes in 30% less time and
// decodes in half.
void SplitBytes(const _Float16 *values, size_t count, uint8_t *low, uint8_t *high) {
    for (size_t i = 0; i < count; i++) {
        uint16_t bits;
        std::memcpy(&bits, &values[i], 2);
        low[i] = uint8_t(bits);
        high[i] = uint8_t(bits >> 8);
    }
}

// false when any value is not finite.
bool JoinBytes(const uint8_t *low, const uint8_t *high, size_t count, _Float16 *values) {
    bool finite = true;
    for (size_t i = 0; i < count; i++) {
        uint16_t bits = uint16_t(low[i] | (high[i] << 8));
        finite &= (bits & 0x7C00) != 0x7C00;
        std::memcpy(&values[i], &bits, 2);
    }
    return finite;
}

// A stream that would not be smaller is stored as it is, so a stream as long
// as its input is never compressed. Answers the bytes written to out.
size_t Pack(const uint8_t *in, size_t count, uint8_t *out, compression_algorithm algorithm) {
    size_t packed = count == 0 ? 0 : compression_encode_buffer(out, count, in, count, nullptr, algorithm);
    if (packed == 0 || packed >= count) {
        std::memcpy(out, in, count);
        return count;
    }
    return packed;
}

// count bytes from a stream of length bytes, in place or in scratch. null
// when the stream is malformed.
const uint8_t *Unpack(const uint8_t *in, size_t length, size_t count, compression_algorithm algorithm,
                      std::vector<uint8_t> &scratch) {
    if (length >= count) {
        return length == count ? in : nullptr;
    }
    scratch.resize(count);
    size_t unpacked = length == 0 ? 0 : compression_decode_buffer(scratch.data(), count, in, length, nullptr, algorithm);
    return unpacked == count ? scratch.data() : nullptr;
}

constexpr char kArchiveMagic[4] = {'W', 'F', 'S', 'M'};
constexpr uint16_t kArchiveVersion = 4;
enum : uint16_t { kFlagBands = 1, kFlagComplete = 2 };
// Far past any real file (a day at 192 kHz in 256-frame bins), so a corrupt
// count cannot ask for gigabytes.
constexpr uint64_t kMaxArchivedBins = uint64_t(1) << 27;

}  // namespace

// The payload is the low stream's length as a uint32, the low stream, then
// the high stream. Each stream holds every plane in order.
std::vector<uint8_t> Summary::encode() const {
    size_t n = base_.count;
    size_t planes = 3 + (bands_ ? kBandCount : 0);
    size_t count = planes * n;
    std::vector<uint8_t> low(count), high(count);
    SplitBytes(base_.lo.data(), n, low.data(), high.data());
    SplitBytes(base_.hi.data(), n, low.data() + n, high.data() + n);
    // Each bin's RMS, not its sum or its mean square. A long bin's sum would
    // not fit a float16, and a quiet bin's mean square rounded to zero in one:
    // a -80 dBFS sine lost its level on a cache reload, though its peaks kept.
    std::vector<_Float16> plane(n);
    auto split = [&](size_t index, const float *sums, size_t stride) {
        for (size_t i = 0; i < n; i++) {
            double frames = binWidth(base_, i);
            plane[i] = (_Float16)(frames > 0 ? std::sqrt(std::max(0.0, double(sums[i * stride])) / frames) : 0);
        }
        SplitBytes(plane.data(), n, low.data() + index * n, high.data() + index * n);
    };
    split(2, base_.sumSquares.data(), 1);
    for (size_t b = 0; bands_ && b < kBandCount; b++) {
        split(3 + b, base_.bandSumSquares.data() + b, kBandCount);
    }
    std::vector<uint8_t> blob(sizeof(ArchiveHeader) + sizeof(uint32_t) + 2 * count);
    uint8_t *streams = blob.data() + sizeof(ArchiveHeader) + sizeof(uint32_t);
    uint32_t lowBytes = uint32_t(Pack(low.data(), count, streams, COMPRESSION_LZ4));
    size_t highBytes = Pack(high.data(), count, streams + lowBytes, COMPRESSION_LZFSE);
    ArchiveHeader header = {};
    std::memcpy(header.magic, kArchiveMagic, 4);
    header.version = kArchiveVersion;
    header.flags = uint16_t((bands_ ? kFlagBands : 0) | (complete_ ? kFlagComplete : 0));
    header.binFrames = uint32_t(base_.binFrames);
    header.binCount = n;
    header.frames = frames_;
    header.totalFrames = totalFrames_;
    header.sampleRate = sampleRate_;
    header.payloadBytes = uint32_t(sizeof(uint32_t) + lowBytes + highBytes);
    std::memcpy(blob.data(), &header, sizeof(header));
    std::memcpy(blob.data() + sizeof(ArchiveHeader), &lowBytes, sizeof(lowBytes));
    blob.resize(sizeof(ArchiveHeader) + header.payloadBytes);
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
    // Any power of two: a long file takes bins coarser than kBaseBinFrames. The
    // bin count bounds the memory, and the frames must end in the last bin.
    uint32_t bf = header.binFrames;
    bool powerOfTwo = bf > 0 && (bf & (bf - 1)) == 0;
    uint64_t n = header.binCount;
    if (!powerOfTwo || n > kMaxArchivedBins ||
        !std::isfinite(header.sampleRate) || header.sampleRate <= 0 || header.totalFrames < 0) {
        return nullptr;
    }
    // The frames must end inside the last bin.
    if (n == 0 ? header.frames != 0
               : (header.frames <= int64_t((n - 1) * bf) || header.frames > int64_t(n * bf))) {
        return nullptr;
    }
    bool bands = header.flags & kFlagBands;
    size_t planes = 3 + (bands ? kBandCount : 0);
    size_t count = planes * n;
    if (header.payloadBytes != length - sizeof(ArchiveHeader) || header.payloadBytes < sizeof(uint32_t)) {
        return nullptr;
    }
    const uint8_t *payload = static_cast<const uint8_t *>(bytes) + sizeof(ArchiveHeader);
    uint32_t lowBytes;
    std::memcpy(&lowBytes, payload, sizeof(lowBytes));
    size_t streamBytes = header.payloadBytes - sizeof(uint32_t);
    if (lowBytes > streamBytes) {
        return nullptr;
    }
    std::vector<uint8_t> lowScratch, highScratch;
    const uint8_t *streams = payload + sizeof(uint32_t);
    const uint8_t *low = Unpack(streams, lowBytes, count, COMPRESSION_LZ4, lowScratch);
    const uint8_t *high = Unpack(streams + lowBytes, streamBytes - lowBytes, count, COMPRESSION_LZFSE, highScratch);
    if (!low || !high) {
        return nullptr;
    }
    auto summary = std::make_unique<Summary>(bf, bands, header.sampleRate);
    Level &base = summary->base_;
    base.lo.resize(n);
    base.hi.resize(n);
    base.sumSquares.resize(n);
    base.bandSumSquares.resize(bands ? n * kBandCount : 0);
    if (!JoinBytes(low, high, n, base.lo.data()) || !JoinBytes(low + n, high + n, n, base.hi.data())) {
        return nullptr;
    }
    // Tests with no early exit, so the loops vectorize.
    bool ordered = true;
    for (uint64_t i = 0; i < n; i++) {
        ordered &= !(base.lo[i] > base.hi[i]);
    }
    if (!ordered) {
        return nullptr;
    }
    std::vector<_Float16> plane(n);
    auto join = [&](size_t index, float *sums, size_t stride) {
        bool valid = JoinBytes(low + index * n, high + index * n, n, plane.data());
        for (uint64_t i = 0; i < n; i++) {
            double rms = float(plane[i]);
            valid &= !(rms < 0);
            sums[i * stride] = float(rms * rms * double(bf));
        }
        // Every bin holds bf frames but the last.
        if (n > 0) {
            double rms = float(plane[n - 1]);
            sums[(n - 1) * stride] = float(rms * rms * double(header.frames - int64_t((n - 1) * bf)));
        }
        return valid;
    };
    if (!join(2, base.sumSquares.data(), 1)) {
        return nullptr;
    }
    for (size_t b = 0; bands && b < kBandCount; b++) {
        if (!join(3 + b, base.bandSumSquares.data() + b, kBandCount)) {
            return nullptr;
        }
    }
    base.count = n;
    summary->frames_ = header.frames;
    summary->totalFrames_ = header.totalFrames;
    summary->complete_ = header.flags & kFlagComplete;
    summary->buildPyramid();
    return summary;
}

#pragma mark - Builder

SummaryBuilder::SummaryBuilder(bool bands, int64_t expectedFrames, double sampleRate)
        : summary_(std::make_unique<Summary>(BinFramesForLength(expectedFrames), bands, sampleRate)) {
    summary_->setTotalFrames(expectedFrames);
    // At most kMaximumBins, however long a length claims to be.
    summary_->reserve(summary_->base_, size_t(std::max<int64_t>(expectedFrames, 0) / summary_->binFrames() + 1));
    if (bands) {
        split_ = std::make_unique<BandSplit>(sampleRate);
    }
}

SummaryBuilder::~SummaryBuilder() = default;

namespace {

// A slice's extremes and sum of squares in one pass, which costs a 256-frame
// bin a quarter fewer instructions than three vDSP calls. TRAP: named
// accumulators, not arrays of them: at -Os the arrays spill, and the pass
// costs twice the three calls.
struct Slice {
    float lo, hi, squares;
};
// Four samples into one set of accumulators.
inline void Take(const float *samples, simd_float4 &lo, simd_float4 &hi, simd_float4 &squares) {
    simd_float4 x;
    std::memcpy(&x, samples, sizeof(x));
    lo = simd_min(lo, x);
    hi = simd_max(hi, x);
    squares = simd_muladd(x, x, squares);
}
Slice MeasureSlice(const float *samples, size_t count) {
    simd_float4 lo0 = INFINITY, lo1 = INFINITY, lo2 = INFINITY, lo3 = INFINITY;
    simd_float4 hi0 = -INFINITY, hi1 = -INFINITY, hi2 = -INFINITY, hi3 = -INFINITY;
    simd_float4 squares0 = 0, squares1 = 0, squares2 = 0, squares3 = 0;
    // 32 samples a pass, then 16, which saves a 256-frame bin about 40 of its
    // 330 instructions. Each set takes its samples in the order 16 a pass
    // would, so the sums are the same.
    const float *at = samples, *passes = samples + (count & ~size_t(31)), *end = samples + count;
    for (; at < passes; at += 32) {
        Take(at, lo0, hi0, squares0);
        Take(at + 4, lo1, hi1, squares1);
        Take(at + 8, lo2, hi2, squares2);
        Take(at + 12, lo3, hi3, squares3);
        Take(at + 16, lo0, hi0, squares0);
        Take(at + 20, lo1, hi1, squares1);
        Take(at + 24, lo2, hi2, squares2);
        Take(at + 28, lo3, hi3, squares3);
    }
    if (count & 16) {
        Take(at, lo0, hi0, squares0);
        Take(at + 4, lo1, hi1, squares1);
        Take(at + 8, lo2, hi2, squares2);
        Take(at + 12, lo3, hi3, squares3);
        at += 16;
    }
    Slice slice = {simd_reduce_min(simd_min(simd_min(lo0, lo1), simd_min(lo2, lo3))),
                   simd_reduce_max(simd_max(simd_max(hi0, hi1), simd_max(hi2, hi3))),
                   simd_reduce_add((squares0 + squares1) + (squares2 + squares3))};
    for (; at < end; at++) {
        slice.lo = std::fmin(slice.lo, *at);
        slice.hi = std::fmax(slice.hi, *at);
        slice.squares += *at * *at;
    }
    return slice;
}

}  // namespace

void SummaryBuilder::append(const float *mono, size_t frames) {
    uint32_t binFrames = summary_->binFrames();
    size_t offset = 0;
    while (offset < frames) {
        // Whole bins go straight into the planes, a block's at a time: a call
        // and three appends a bin cost more than the bin's pass.
        size_t whole = binFill_ == 0 ? (frames - offset) / binFrames : 0;
        if (whole > 0) {
            Summary::Level &base = summary_->base_;
            size_t at = base.count;
            base.lo.resize(at + whole);
            base.hi.resize(at + whole);
            base.sumSquares.resize(at + whole);
            if (split_) {
                base.bandSumSquares.resize((at + whole) * kBandCount);
            }
            for (size_t bin = at; bin < at + whole; bin++, offset += binFrames) {
                Slice slice = MeasureSlice(mono + offset, binFrames);
                base.lo[bin] = (_Float16)(std::isfinite(slice.lo) ? slice.lo : 0.0f);
                base.hi[bin] = (_Float16)(std::isfinite(slice.hi) ? slice.hi : 0.0f);
                base.sumSquares[bin] = std::isfinite(slice.squares) ? slice.squares : 0.0f;
                if (split_) {
                    std::array<double, kBandCount> bands = {0, 0, 0};
                    split_->addSumSquares(mono + offset, binFrames, bands.data());
                    for (size_t b = 0; b < kBandCount; b++) {
                        base.bandSumSquares[bin * kBandCount + b] = float(bands[b]);
                    }
                }
            }
            base.count += whole;
            summary_->frames_ += int64_t(whole) * binFrames;
            continue;
        }
        size_t take = std::min<size_t>(frames - offset, binFrames - binFill_);
        // A corrupt file can decode NaN or Inf: NaN geometry in every view,
        // persisted under the file's key. Extremes skip NaN and drop Inf, and
        // a slice whose sum is not finite adds nothing.
        Slice slice = MeasureSlice(mono + offset, take);
        float lo = std::isfinite(slice.lo) ? slice.lo : 0, hi = std::isfinite(slice.hi) ? slice.hi : 0;
        lo_ = binFill_ ? std::fmin(lo_, lo) : lo;
        hi_ = binFill_ ? std::fmax(hi_, hi) : hi;
        if (std::isfinite(slice.squares)) {
            sumSquares_ += double(slice.squares);
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
    summary_->derive(false);
}

void SummaryBuilder::flushBin() {
    summary_->appendBin(lo_, hi_, sumSquares_, bandSumSquares_.data(), binFill_);
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
