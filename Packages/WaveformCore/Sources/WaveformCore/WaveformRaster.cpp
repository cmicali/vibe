//
//  WaveformRaster.cpp
//  WaveformCore
//

#include "WaveformRaster.hpp"

#include <algorithm>
#include <climits>
#include <cstdlib>

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
                      std::vector<float> &samples, const std::vector<float> &target) {
    std::vector<float> remapped = target;
    if (stride == 0 || samples.size() != from.columnCount() * stride || target.size() != to.columnCount() * stride) {
        samples.swap(remapped);
        return;
    }
    // A point of the track, so a new track's columns take the old one's at the
    // same share of its length.
    double scale = from.totalFrames > 0 && to.totalFrames > 0
            ? double(from.totalFrames) / double(to.totalFrames) : 1;
    size_t fromOffsets[2] = {0, from.parts[0].count * stride};
    size_t offset = 0;
    for (const StepPart &part : to.parts) {
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
                    const float *in = &samples[fromOffsets[source] + size_t(column) * stride];
                    std::copy(in, in + stride, &remapped[offset + i * stride]);
                }
            }
        }
        offset += part.count * stride;
    }
    samples.swap(remapped);
}

ColumnCoverage::ColumnCoverage(int height)
        : height_(std::max(0, height)), steps_(size_t(height_) + 1, 0.0f), partial_(size_t(height_), 0.0f) {}

void ColumnCoverage::clear() {
    std::fill(steps_.begin(), steps_.end(), 0.0f);
    std::fill(partial_.begin(), partial_.end(), 0.0f);
}

void ColumnCoverage::addSpan(double bottom, double top, float weight) {
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
        partial_[size_t(r0)] += weight * float(y1 - y0);
        return;
    }
    int full0 = int(std::ceil(y0)), full1 = r1;
    if (double(full0) > y0) {
        partial_[size_t(r0)] += weight * float(double(full0) - y0);
    }
    if (full1 > full0) {
        steps_[size_t(full0)] += weight;
        steps_[size_t(full1)] -= weight;
    }
    if (y1 > double(full1) && full1 < height_) {
        partial_[size_t(full1)] += weight * float(y1 - double(full1));
    }
}

float ColumnCoverage::at(int rowFromTop) const {
    if (rowFromTop < 0 || rowFromTop >= height_) {
        return 0;
    }
    float run = 0;
    for (int r = 0; r <= rowFromTop; r++) {
        run += steps_[size_t(r)];
    }
    return run + partial_[size_t(rowFromTop)];
}

void ColumnCoverage::writeMask(uint32_t *out, ptrdiff_t rowStride) const {
    float run = 0;
    for (int r = 0; r < height_; r++, out += rowStride) {
        run += steps_[size_t(r)];
        float value = std::clamp(run + partial_[size_t(r)], 0.0f, 1.0f);
        *out = uint32_t(std::lround(value * 255.0f)) * 0x01010101u;
    }
}

ColumnPaint::ColumnPaint(int height) : height_(std::max(0, height)), rows_(size_t(height_) * 4, 0.0f) {}

void ColumnPaint::clear() {
    spans_.clear();
}

void ColumnPaint::paintSpan(double bottom, double top, float red, float green, float blue) {
    bottom = std::fmax(bottom, 0.0);
    top = std::fmin(top, double(height_));
    if (top > bottom) {
        spans_.push_back({bottom, top, red, green, blue});
    }
}

void ColumnPaint::write(uint32_t *out, ptrdiff_t rowStride) {
    std::fill(rows_.begin(), rows_.end(), 0.0f);
    // Between two neighbouring span edges one span shows: the last painted
    // over that stretch. Each stretch adds its color to the rows it crosses.
    edges_.clear();
    for (const Span &span : spans_) {
        edges_.push_back(span.bottom);
        edges_.push_back(span.top);
    }
    std::sort(edges_.begin(), edges_.end());
    for (size_t e = 0; e + 1 < edges_.size(); e++) {
        double bottom = edges_[e], top = edges_[e + 1];
        if (!(top > bottom)) {
            continue;
        }
        double middle = 0.5 * (bottom + top);
        const Span *shown = nullptr;
        for (const Span &span : spans_) {
            if (span.bottom <= middle && middle < span.top) {
                shown = &span;
            }
        }
        if (!shown) {
            continue;
        }
        // Rows from the top: the stretch is [y0, y1).
        double y0 = double(height_) - top, y1 = double(height_) - bottom;
        int r0 = int(std::floor(y0)), r1 = std::min(height_ - 1, int(std::ceil(y1)) - 1);
        for (int r = r0; r <= r1; r++) {
            float cover = float(std::fmin(y1, double(r + 1)) - std::fmax(y0, double(r)));
            float *row = &rows_[size_t(r) * 4];
            row[0] += shown->red * cover;
            row[1] += shown->green * cover;
            row[2] += shown->blue * cover;
            row[3] += cover;
        }
    }
    auto byte = [](float value) { return uint32_t(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f)); };
    for (int r = 0; r < height_; r++, out += rowStride) {
        const float *row = &rows_[size_t(r) * 4];
        *out = byte(row[3]) << 24 | byte(row[0]) << 16 | byte(row[1]) << 8 | byte(row[2]);
    }
}

}  // namespace wavecore
