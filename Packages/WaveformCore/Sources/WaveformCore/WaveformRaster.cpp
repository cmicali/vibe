//
//  WaveformRaster.cpp
//  WaveformCore
//

#include "WaveformRaster.hpp"

#include <simd/simd.h>

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <iterator>

namespace wavecore {

StepWindow StepWindowForPixels(int64_t totalFrames, double framesPerPixel, double columnsPerPixel, int x0, int x1) {
    StepWindow window;
    window.totalFrames = totalFrames;
    if (!(totalFrames > 0) || !(framesPerPixel > 0) || !(columnsPerPixel > 0) || x1 <= x0) {
        return window;
    }
    double steps = 2.0 * std::log2(framesPerPixel / columnsPerPixel);
    if (!std::isfinite(steps)) {
        return window;
    }
    double finer = std::floor(steps);
    window.coarse = steps - finer;
    for (int p = 0; p < 2; p++) {
        StepPart &part = window.parts[p];
        part.step = int(finer) + p;
        double framesPerColumn = part.framesPerColumn();
        double end = std::ceil(double(totalFrames) / framesPerColumn);
        double first = std::fmax(0.0, std::floor(double(x0) * framesPerPixel / framesPerColumn));
        double last = std::fmin(end, std::ceil(double(x1) * framesPerPixel / framesPerColumn));
        part.first = int64_t(first);
        part.count = last > first ? size_t(last - first) : 0;
    }
    return window;
}

void RemapStepSamples(const StepWindow &from, const StepWindow &to, size_t stride,
                      std::vector<float> &samples, const std::vector<float> &target, std::vector<float> &scratch) {
    std::vector<float> &remapped = scratch;
    remapped.assign(target.begin(), target.end());
    if (stride == 0 || samples.size() != from.columnCount() * stride || target.size() != to.columnCount() * stride) {
        samples.swap(remapped);
        return;
    }
    // A point of the track, so a new track's columns take the old one's at the
    // same share of its length.
    double scale = from.totalFrames > 0 && to.totalFrames > 0
            ? double(from.totalFrames) / double(to.totalFrames) : 1;
    for (int t = 0; t < 2; t++) {
        const StepPart &part = to.parts[t];
        int source = -1, distance = INT_MAX;
        for (int p = 0; p < 2; p++) {
            int d = std::abs(from.parts[p].step - part.step);
            if (from.parts[p].count > 0 && d < distance) {
                source = p;
                distance = d;
            }
        }
        if (source >= 0) {
            const StepPart &old = from.parts[source];
            double framesPerColumn = part.framesPerColumn(), oldFramesPerColumn = old.framesPerColumn();
            for (size_t i = 0; i < part.count; i++) {
                double center = (double(part.first) + double(i) + 0.5) * framesPerColumn * scale;
                double column = std::floor(center / oldFramesPerColumn) - double(old.first);
                if (column >= 0 && column < double(old.count)) {
                    const float *in = &samples[(from.offset(source) + size_t(column)) * stride];
                    std::copy(in, in + stride, &remapped[(to.offset(t) + i) * stride]);
                }
            }
        }
    }
    samples.swap(remapped);
}

namespace {

uint32_t Byte(float value) {
    return uint32_t(std::clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f);
}

}  // namespace

ColumnCoverage::ColumnCoverage(int height)
        : height_(std::max(0, height)), steps_((size_t(height_) + 1) * kLanes, 0.0f),
          partial_(size_t(height_) * kLanes, 0.0f), touched_((size_t(height_) + 64) / 64, 0) {}

// Ascending, each row once.
template <typename Visit>
void ColumnCoverage::forEachTouched(Visit visit) const {
    for (size_t w = 0; w < touched_.size(); w++) {
        for (uint64_t bits = touched_[w]; bits; bits &= bits - 1) {
            visit(int(w * 64) + __builtin_ctzll(bits));
        }
    }
}

void ColumnCoverage::addSpan(int lane, double bottom, double top, float weight) {
    if (!(top > bottom) || !(weight != 0)) {
        return;
    }
    // Rows from the top: the span is [y0, y1).
    double y0 = std::fmax(0.0, double(height_) - top);
    double y1 = std::fmin(double(height_), double(height_) - bottom);
    if (!(y1 > y0)) {
        return;
    }
    int r0 = int(std::floor(y0)), r1 = int(std::floor(y1));
    if (r0 == r1) {
        partial_[size_t(r0) * kLanes + size_t(lane)] += weight * float(y1 - y0);
        touch(r0);
        return;
    }
    int full0 = int(std::ceil(y0)), full1 = r1;
    if (double(full0) > y0) {
        partial_[size_t(r0) * kLanes + size_t(lane)] += weight * float(double(full0) - y0);
        touch(r0);
    }
    if (full1 > full0) {
        steps_[size_t(full0) * kLanes + size_t(lane)] += weight;
        steps_[size_t(full1) * kLanes + size_t(lane)] -= weight;
        touch(full0);
        touch(full1);
    }
    if (y1 > double(full1) && full1 < height_) {
        partial_[size_t(full1) * kLanes + size_t(lane)] += weight * float(y1 - double(full1));
        touch(full1);
    }
}

float ColumnCoverage::at(int lane, int rowFromTop) const {
    if (rowFromTop < 0 || rowFromTop >= height_) {
        return 0;
    }
    float run = 0;
    for (int r = 0; r <= rowFromTop; r++) {
        run += steps_[size_t(r) * kLanes + size_t(lane)];
    }
    return run + partial_[size_t(rowFromTop) * kLanes + size_t(lane)];
}

void ColumnCoverage::writeMask(uint32_t *out, ptrdiff_t rowStride, int lanes) {
    static_assert(kLanes == 4, "a row's lanes are one simd_float4");
    auto load = [](const float *at) {
        simd_float4 value;
        std::memcpy(&value, at, sizeof(value));
        return value;
    };
    // Byte's rounding, a lane each.
    auto pixels = [](simd_float4 value) {
        return simd_uint(simd_clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f) * 0x01010101u;
    };
    size_t bytes = size_t(std::clamp(lanes, 0, kLanes)) * sizeof(uint32_t);
    int next = 0;
    auto fill = [&](int end, simd_uint4 row) {
        if (simd_reduce_max(row) == 0) {
            return;
        }
        uint32_t *at = out + ptrdiff_t(next) * rowStride;
        if (bytes == sizeof(row)) {
            for (int r = next; r < end; r++, at += rowStride) {
                std::memcpy(at, &row, sizeof(row));
            }
        } else {
            for (int r = next; r < end; r++, at += rowStride) {
                std::memcpy(at, &row, bytes);
            }
        }
    };
    // The same sums in the same order as a pass over every row: a row no span
    // touched adds nothing to a lane's run.
    simd_float4 run = 0;
    simd_uint4 between = 0;
    forEachTouched([&](int r) {
        float *step = &steps_[size_t(r) * kLanes];
        if (r >= height_) {
            std::fill_n(step, kLanes, 0.0f);
            return;
        }
        fill(r, between);
        run += load(step);
        std::fill_n(step, kLanes, 0.0f);
        next = r;
        float *partial = &partial_[size_t(r) * kLanes];
        fill(r + 1, pixels(run + load(partial)));
        std::fill_n(partial, kLanes, 0.0f);
        next = r + 1;
        between = pixels(run);
    });
    fill(height_, between);
    std::fill(touched_.begin(), touched_.end(), 0);
}

ColumnPaint::ColumnPaint(int height) : height_(std::max(0, height)) {}

void ColumnPaint::paintSpan(double bottom, double top, float red, float green, float blue) {
    bottom = std::fmax(bottom, 0.0);
    top = std::fmin(top, double(height_));
    if (top > bottom && count_ < kMaxSpans) {
        spans_[count_++] = {bottom, top, red, green, blue};
    }
}

namespace {

// A row that holds an edge, summed from the stretches crossing it.
struct PartialRow {
    int row = -1;
    float red = 0, green = 0, blue = 0, alpha = 0;

    void add(float cover, float r, float g, float b) {
        red += r * cover;
        green += g * cover;
        blue += b * cover;
        alpha += cover;
    }
    void flush(uint32_t *out, ptrdiff_t rowStride) {
        if (row >= 0) {
            out[row * rowStride] = Byte(alpha) << 24 | Byte(red) << 16 | Byte(green) << 8 | Byte(blue);
        }
        *this = PartialRow();
    }
};

}  // namespace

void ColumnPaint::write(uint32_t *out, ptrdiff_t rowStride) {
    // Between two neighbouring span edges one span shows: the last painted
    // over that stretch. Full rows take its color at once. A row that holds
    // an edge sums the stretches crossing it.
    double edges[2 * kMaxSpans] = {};
    size_t sorted = 0;
    for (size_t s = 0; s < count_; s++) {
        for (double edge : {spans_[s].bottom, spans_[s].top}) {
            // Coincident band edges divide no area. Sort each position once.
            size_t i = 0;
            while (i < sorted && edges[i] < edge) i++;
            if (i < sorted && edges[i] == edge) continue;
            for (size_t j = sorted++; j > i; j--) edges[j] = edges[j - 1];
            edges[i] = edge;
        }
    }
    PartialRow partial;
    const Span *shown = nullptr;
    auto addPartial = [&](int row, double cover) {
        if (partial.row != row) {
            partial.flush(out, rowStride);
            partial.row = row;
        }
        partial.add(float(cover), shown->red, shown->green, shown->blue);
    };
    // From the top down, so rows arrive in order.
    for (size_t e = sorted; e-- > 1;) {
        double bottom = edges[e - 1], top = edges[e];
        if (!(top > bottom)) {
            continue;
        }
        double middle = 0.5 * (bottom + top);
        shown = nullptr;
        for (size_t i = count_; i-- > 0;) {
            if (spans_[i].bottom <= middle && middle < spans_[i].top) {
                shown = &spans_[i];
                break;
            }
        }
        if (!shown) {
            continue;
        }
        // Rows from the top: the stretch is [y0, y1).
        double y0 = double(height_) - top, y1 = double(height_) - bottom;
        int first = int(std::floor(y0)), full0 = int(std::ceil(y0)), full1 = int(std::floor(y1));
        if (full1 < full0) {
            // Inside one row.
            addPartial(first, y1 - y0);
            continue;
        }
        if (double(full0) > y0) {
            addPartial(first, double(full0) - y0);
        }
        if (full1 > full0) {
            partial.flush(out, rowStride);
            uint32_t color = 0xff000000u | Byte(shown->red) << 16 | Byte(shown->green) << 8 | Byte(shown->blue);
            for (int r = full0; r < full1; r++) {
                out[r * rowStride] = color;
            }
        }
        if (y1 > double(full1) && full1 < height_) {
            addPartial(full1, y1 - double(full1));
        }
    }
    partial.flush(out, rowStride);
}

}  // namespace wavecore
