//
//  WaveformRaster.hpp
//  WaveformCore
//
//  Drawing a summary's columns onto device pixels: the zoom steps they are
//  read at, the window of columns a view needs, and exact coverage of one
//  pixel column at a time.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace wavecore {

// Columns are read only at steps: step s holds columns of 2^(s/2) frames on
// the grid from frame 0. A view at any zoom draws the two steps around it,
// each resampled by area and crossfaded. A step's columns are fixed, so a
// resize, zoom or scroll only changes how they are resampled, and every pixel
// is a continuous function of the view. Columns reduced per pixel instead
// reshuffle as each resize moves every column's edges.
inline double StepFrames(int step) {
    return std::exp2(0.5 * step);
}

// The columns of one step a window reads: [first, first + count) of its grid.
struct StepPart {
    int step = 0;
    int64_t first = 0;
    size_t count = 0;

    double framesPerColumn() const { return StepFrames(step); }
    bool operator==(const StepPart &other) const {
        return step == other.step && first == other.first && count == other.count;
    }
};

// What a window of pixels draws: the finer step, whose columns are no wider
// than the frames a column should cover, then the next coarser one. coarse is
// the coarser part's weight, approaching 1 as the view nears its scale.
struct StepWindow {
    StepPart parts[2];
    double coarse = 0;
    int64_t totalFrames = 0;

    size_t columnCount() const { return parts[0].count + parts[1].count; }
    // Part p's weight in the crossfade, and where its columns start in a
    // layout of both parts, the finer first.
    float weight(int p) const { return float(p ? coarse : 1 - coarse); }
    size_t offset(int p) const { return p ? parts[0].count : 0; }
    // Two windows with the same columns draw from the same samples, whatever
    // their weights.
    bool sameColumns(const StepWindow &other) const {
        return parts[0] == other.parts[0] && parts[1] == other.parts[1] && totalFrames == other.totalFrames;
    }
};

// Pixel x covers frames [x * framesPerPixel, (x + 1) * framesPerPixel), and
// the view wants columnsPerPixel columns a pixel. The parts cover pixels
// [x0, x1), leaving out columns past totalFrames.
StepWindow StepWindowForPixels(int64_t totalFrames, double framesPerPixel, double columnsPerPixel, int x0, int x1);

// Moves samples laid out for from, stride floats a column, to to's layout:
// each column takes the from column under the same point of the track, read
// from the part of its own step or else the nearest step. Where from has no
// column there, the column takes target's value, which is laid out for to.
// The result is built in scratch and swapped in, so a caller that keeps
// scratch allocates nothing.
void RemapStepSamples(const StepWindow &from, const StepWindow &to, size_t stride,
                      std::vector<float> &samples, const std::vector<float> &target, std::vector<float> &scratch);

// The share of each column of [first, first + count) under pixel x, a pixel
// spanning perPixel columns: visit(column, share) over the columns it
// overlaps, shares summing to the part of the pixel they cover.
template <typename Visit>
inline void ForEachColumnShare(int x, double perPixel, int64_t first, size_t count, Visit visit) {
    double u0 = double(x) * perPixel - double(first);
    double u1 = u0 + perPixel;
    long begin = long(std::floor(std::fmax(u0, 0.0)));
    long end = long(std::ceil(std::fmin(u1, double(count))));
    for (long i = begin; i < end; i++) {
        double overlap = std::fmin(u1, double(i + 1)) - std::fmax(u0, double(i));
        if (overlap > 0) {
            visit(size_t(i), float(overlap / perPixel));
        }
    }
}

// The two columns of a grid's [first, first + count) around a frame and how
// far it lies between their centers, for a value read linearly from column to
// column. Clamped at the ends.
struct ColumnPair {
    size_t left;
    size_t right;
    float toRight;
};

inline ColumnPair ColumnPairAroundFrame(double frame, double framesPerColumn, int64_t first, size_t count) {
    if (count == 0) {
        return {0, 0, 0};
    }
    double u = frame / framesPerColumn - 0.5 - double(first);
    double last = double(count - 1);
    if (!(u > 0)) {
        return {0, 0, 0};
    }
    if (!(u < last)) {
        return {count - 1, count - 1, 0};
    }
    double left = std::floor(u);
    return {size_t(left), size_t(left) + 1, float(u - left)};
}

// Up to kLanes neighbouring pixel columns' coverage, accumulated exactly: a
// partly covered row by its part. Spans arrive y-up, 0 at a column's bottom.
// A span costs its two ends whatever its height. Coverage can exceed 1 until
// it is written. The columns' rows are written together, one store a row.
class ColumnCoverage {
public:
    static constexpr int kLanes = 4;

    explicit ColumnCoverage(int height);
    int height() const { return height_; }

    // Pixel columns [x0, x1) into out, column x0 first, kLanes at a time:
    // spans(x, add) adds column x's spans with add(bottom, top, weight).
    template <typename Spans>
    void draw(int x0, int x1, uint32_t *out, ptrdiff_t rowStride, Spans spans) {
        for (int x = x0; x < x1; x += kLanes) {
            int lanes = std::min(kLanes, x1 - x);
            for (int lane = 0; lane < lanes; lane++) {
                spans(x + lane, [&](double bottom, double top, float weight) { addSpan(lane, bottom, top, weight); });
            }
            writeMask(out + (x - x0), rowStride, lanes);
        }
    }

    // Column lane's [bottom, top] in y-up pixels, times weight.
    void addSpan(int lane, double bottom, double top, float weight);
    // Column lane's coverage of a row, from the top, unclamped.
    float at(int lane, int rowFromTop) const;
    // Columns [0, lanes)' covered rows from the top, clamped to 0...1, as
    // premultiplied white: 32-bit ARGB in host order. A row no span covers is
    // left as out held it, so out starts cleared. out is column 0's top row,
    // rowStride pixels a row, so a negative stride writes bottom-up. Leaves
    // the coverage clear for the next columns.
    void writeMask(uint32_t *out, ptrdiff_t rowStride, int lanes);

private:
    // Full rows as a difference array, partial rows directly, a row's lanes
    // together. Coverage changes only at the rows the spans touched, a bit
    // each, so a mask walks those in order, fills the runs between them and
    // resets only them.
    void touch(int row) { touched_[size_t(row) >> 6] |= uint64_t(1) << (row & 63); }
    template <typename Visit> void forEachTouched(Visit visit) const;

    int height_;
    std::vector<float> steps_;      // (height + 1) × kLanes
    std::vector<float> partial_;    // height × kLanes
    std::vector<uint64_t> touched_; // a bit a row, height + 1
};

// One pixel column painted in order with colors: each later span covers the
// earlier ones under it. A row takes each color by the area it shows there,
// so edges that coincide do not stack their coverage into a bolder line.
class ColumnPaint {
public:
    static constexpr size_t kMaxSpans = 16;

    explicit ColumnPaint(int height);

    void clear() { count_ = 0; }
    // [bottom, top] in y-up pixels, in an opaque color, 0...1 a component.
    // Spans past kMaxSpans are dropped.
    void paintSpan(double bottom, double top, float red, float green, float blue);
    // Premultiplied 32-bit ARGB in host order, rows from the top, stepping
    // rowStride pixels a row. Only rows a span covers are written, so out
    // starts cleared.
    void write(uint32_t *out, ptrdiff_t rowStride);

private:
    struct Span {
        double bottom, top;
        float red, green, blue;
    };
    int height_;
    Span spans_[kMaxSpans];
    size_t count_ = 0;
};

}  // namespace wavecore
