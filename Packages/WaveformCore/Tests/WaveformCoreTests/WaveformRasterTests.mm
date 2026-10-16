//
//  WaveformRasterTests.mm
//  VibeTests
//
//  WaveformCore's raster: the steps and windows, exact coverage, the area
//  resample, and the property they exist for: a picture that changes
//  continuously with the view.
//

#import <XCTest/XCTest.h>

#include "WaveformRaster.hpp"

#include <random>
#include <vector>

using wavecore::ColumnCoverage;
using wavecore::StepPart;
using wavecore::StepWindow;

@interface WaveformRasterTests : XCTestCase
@end

// One mask pixel's alpha.
static uint32_t VibeAlpha(uint32_t pixel) {
    return pixel >> 24;
}

@implementation WaveformRasterTests

- (void)testASpanCoversEachRowByItsPart {
    ColumnCoverage column(10);
    // y-up 2.25 to 4.75: rows from the top 5.25 to 7.75.
    column.addSpan(1, 2.25, 4.75, 1);
    XCTAssertEqualWithAccuracy(column.at(1, 4), 0, 1e-6);
    XCTAssertEqualWithAccuracy(column.at(1, 5), 0.75, 1e-6);
    XCTAssertEqualWithAccuracy(column.at(1, 6), 1, 1e-6);
    XCTAssertEqualWithAccuracy(column.at(1, 7), 0.75, 1e-6);
    XCTAssertEqualWithAccuracy(column.at(1, 8), 0, 1e-6);
    XCTAssertEqual(column.at(0, 6), 0, @"each lane is its own column");
    // Inside one row, and clipped at both ends.
    column.addSpan(1, 9.1, 9.4, 1);
    XCTAssertEqualWithAccuracy(column.at(1, 0), 0.3, 1e-6);
    ColumnCoverage clipped(4);
    clipped.addSpan(0, -5, 50, 0.5f);
    for (int r = 0; r < 4; r++) XCTAssertEqualWithAccuracy(clipped.at(0, r), 0.5, 1e-6);
    clipped.clear();
    XCTAssertEqual(clipped.at(0, 2), 0);
}

// Premultiplied white, clamped, and in the row order the stride asks for.
- (void)testTheMaskIsClampedWhiteInEitherRowOrder {
    ColumnCoverage column(3);
    column.addSpan(0, 2, 3, 2);
    column.addSpan(0, 1, 2, 0.5f);
    column.addSpan(1, 0, 3, 1);
    uint32_t pixels[3][2] = {};
    column.writeMask(&pixels[0][0], 2, 2);
    XCTAssertEqual(pixels[0][0], 0xffffffffu);
    XCTAssertEqual(pixels[1][0], 0x80808080u);
    XCTAssertEqual(pixels[2][0], 0u);
    for (int r = 0; r < 3; r++) XCTAssertEqual(pixels[r][1], 0xffffffffu, @"the second column, row %d", r);
    uint32_t flipped[3] = {};
    column.writeMask(flipped + 2, -1, 1);
    XCTAssertEqual(flipped[0], 0u);
    XCTAssertEqual(flipped[1], 0x80808080u);
    XCTAssertEqual(flipped[2], 0xffffffffu);
}

- (void)testTheWindowsStepsBracketTheView {
    for (double fpp : {1.0, 1.3, 2.0, 255.9, 256.0, 6611.5}) {
        for (double columnsPerPixel : {0.5, 1.0, 8.0}) {
            StepWindow window = wavecore::StepWindowForPixels(1 << 24, fpp, columnsPerPixel, 0, 100);
            double frames = fpp / columnsPerPixel;
            XCTAssertLessThanOrEqual(window.parts[0].framesPerColumn(), frames * (1 + 1e-12));
            XCTAssertGreaterThan(window.parts[1].framesPerColumn(), frames * (1 - 1e-12));
            XCTAssertEqual(window.parts[1].step, window.parts[0].step + 1);
            XCTAssertGreaterThanOrEqual(window.coarse, 0);
            XCTAssertLessThan(window.coarse, 1);
        }
    }
    XCTAssertEqual(wavecore::StepFrames(16), 256);
}

// A window reads the columns under its pixels, on the grid from frame 0, and
// none past the track.
- (void)testAWindowReadsTheColumnsUnderItsPixels {
    // 256 frames a pixel and a column a pixel: step 16, exactly.
    StepWindow window = wavecore::StepWindowForPixels(100000, 256, 1, 10, 20);
    XCTAssertEqual(window.parts[0].step, 16);
    XCTAssertEqual(window.coarse, 0);
    XCTAssertEqual(window.parts[0].first, 10);
    XCTAssertEqual(window.parts[0].count, 10u);
    StepWindow whole = wavecore::StepWindowForPixels(100000, 256, 1, 0, 1000);
    XCTAssertEqual(whole.parts[0].count, 391u, @"ceil(100000 / 256)");
    XCTAssertEqual(wavecore::StepWindowForPixels(0, 256, 1, 0, 10).columnCount(), 0u);
    // Another scale inside the same step reads the same columns.
    StepWindow narrower = wavecore::StepWindowForPixels(100000, 260, 1, 0, 1024);
    XCTAssertTrue(narrower.sameColumns(whole));
    XCTAssertNotEqual(narrower.coarse, whole.coarse);
}

// Uniform columns land as uniform pixels whatever the ratio, so a steady
// level never shows a comb: each pixel's shares add up to one.
- (void)testSharesSumToOneEveryPixel {
    for (double ratio : {1.0, 1.21, 1.414, 0.73, 3.3}) {
        StepPart part{12, 0, 100000};
        for (int x = 0; x < 50; x++) {
            float sum = 0;
            wavecore::ForEachColumnShare(x, ratio * part.framesPerColumn(), part,
                                         [&](size_t, float share) { sum += share; });
            XCTAssertEqualWithAccuracy(sum, 1, 1e-5, @"ratio %g", ratio);
        }
    }
}

// A column narrower than a pixel lands in it by its share, and one that
// straddles two pixels splits between them.
- (void)testAColumnLandsByItsShareOfEachPixel {
    // Step 8: 16 frames a column. Column 1 covers frames [16, 32); pixels are
    // 12 frames from frame 0: [12, 24) holds 8 of them, [24, 36) 8.
    StepPart part{8, 1, 1};
    std::vector<float> shares(3, 0);
    for (int x = 0; x < 3; x++) {
        wavecore::ForEachColumnShare(x, 12, part, [&](size_t column, float share) {
            XCTAssertEqual(column, 0u);
            shares[size_t(x)] += share;
        });
    }
    XCTAssertEqualWithAccuracy(shares[0], 0, 1e-6);
    XCTAssertEqualWithAccuracy(shares[1], 8.0 / 12, 1e-6);
    XCTAssertEqualWithAccuracy(shares[2], 8.0 / 12, 1e-6);
}

- (void)testAValueReadsLinearlyBetweenColumnCenters {
    StepPart part{2, 10, 4};  // 2 frames a column, columns 10...13
    wavecore::ColumnPair pair = wavecore::ColumnPairAroundFrame(22, part);  // between 11's and 12's centers
    XCTAssertEqual(pair.left, 0u);
    XCTAssertEqual(pair.right, 1u);
    XCTAssertEqualWithAccuracy(pair.toRight, 0.5, 1e-6);
    XCTAssertEqual(wavecore::ColumnPairAroundFrame(0, part).left, 0u);
    XCTAssertEqual(wavecore::ColumnPairAroundFrame(1000, part).right, 3u);
}

// What the steps are for. The same columns drawn at two nearly equal scales
// differ by little at every pixel: no pixel can jump, because each is a
// continuous function of the scale. A per-pixel max reshuffles instead.
- (void)testAPictureChangesContinuouslyWithTheScale {
    std::mt19937 rng(5);
    std::uniform_real_distribution<float> height(0, 40);
    StepPart part{0, 0, 4000};
    std::vector<float> tops(part.count);
    for (float &top : tops) top = height(rng);
    auto draw = [&](double fpp) {
        std::vector<uint32_t> pixels(300 * 40);
        ColumnCoverage column(40);
        for (int x = 0; x < 300; x++) {
            column.clear();
            wavecore::ForEachColumnShare(x, fpp, part, [&](size_t i, float share) {
                column.addSpan(0, 0, tops[i], share);
            });
            column.writeMask(&pixels[size_t(x)], 300, 1);
        }
        return pixels;
    };
    std::vector<uint32_t> a = draw(6.0), b = draw(6.0 * 1.0005);
    uint32_t worst = 0;
    for (size_t i = 0; i < a.size(); i++) {
        worst = std::max(worst, (uint32_t)std::abs((int)VibeAlpha(a[i]) - (int)VibeAlpha(b[i])));
    }
    // Pixel 299's frames move by 0.9 of a column: a change of 0.15 at most.
    XCTAssertLessThan(worst, 0.16 * 255);
}

// A remap keeps each column's samples with its frames across a step and a
// window move, and takes the target where the old window had nothing.
- (void)testARemapCarriesColumnsByTheirFrames {
    StepWindow from = wavecore::StepWindowForPixels(1 << 20, 4, 1, 100, 110);
    std::vector<float> samples;
    for (const StepPart &part : from.parts) {
        for (size_t i = 0; i < part.count; i++) samples.push_back(float(part.step * 10000 + part.first + i));
    }
    // Zoomed out a step, over frames 425 to 481.
    StepWindow to = wavecore::StepWindowForPixels(1 << 20, 4 * M_SQRT2 * 1.001, 1, 75, 85);
    XCTAssertEqual(to.parts[0].step, from.parts[1].step);
    std::vector<float> target(to.columnCount(), -1);
    wavecore::RemapStepSamples(from, to, 1, samples, target);
    XCTAssertEqual(samples.size(), target.size());
    const StepPart &same = to.parts[0], &old = from.parts[1];
    for (size_t i = 0; i < same.count; i++) {
        int64_t column = same.first + (int64_t)i;
        BOOL held = column >= old.first && column < old.first + (int64_t)old.count;
        XCTAssertEqual(samples[i], held ? float(old.step * 10000 + column) : -1.0f, @"column %lld", column);
    }
    // The coarser step is new: its columns read the nearest step's.
    XCTAssertGreaterThan(samples[same.count], float(old.step * 10000));
}

- (void)testColorSpansPaintInOrder {
    wavecore::ColumnPaint column(4);
    column.paintSpan(0, 4, 1, 0, 0);
    column.paintSpan(1, 3, 0, 0, 1);
    column.paintSpan(1.5, 2.5, 0, 1, 0);
    uint32_t pixels[4] = {};
    column.write(pixels, 1);
    // Row 0 (top): red alone. Rows 1 and 2: half blue, half green over blue.
    XCTAssertEqual(pixels[0], 0xffff0000u);
    XCTAssertEqual(pixels[1], 0xff008080u);
    XCTAssertEqual(pixels[2], 0xff008080u);
    XCTAssertEqual(pixels[3], 0xffff0000u);
}

// Spans that share an edge cover a partial row by its part once, in the color
// painted last, however many are painted.
- (void)testCoincidingEdgesDoNotStack {
    wavecore::ColumnPaint column(2);
    for (int i = 0; i < 7; i++) {
        column.paintSpan(0.5, 1.5, i == 6 ? 1 : 0, i == 6 ? 0 : 1, 0);
    }
    uint32_t pixels[2] = {};
    column.write(pixels, 1);
    XCTAssertEqual(pixels[0], 0x80800000u);
    XCTAssertEqual(pixels[1], 0x80800000u);
}

@end
