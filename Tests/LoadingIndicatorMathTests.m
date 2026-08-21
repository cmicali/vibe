//
//  LoadingIndicatorMathTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "LoadingIndicatorMath.h"

@interface LoadingIndicatorMathTests : XCTestCase
@end

@implementation LoadingIndicatorMathTests

// The waveform style is a regression fence around "pixel-identical": these are
// the numbers the control drew before the row style existed, at several
// widths, so the extraction cannot have moved the waveform's line.
- (void)testWaveformStyleReturnsTheHistoricalConstants {
    for (NSNumber *widthNumber in @[ @200, @480, @1024, @3000 ]) {
        CGFloat width = widthNumber.doubleValue;
        VibeLoadingIndicatorMetrics m =
                VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleWaveform, width);
        XCTAssertEqual(m.height, 1);
        XCTAssertEqual(m.cornerRadius, 0);
        XCTAssertEqualWithAccuracy(m.bandWidth, MAX(width * 0.35, 40), 0.0001);
        XCTAssertEqual(m.frontFadePoints, 14);
        XCTAssertEqualWithAccuracy(m.trackAlpha, 0.275, 0.0001);
        XCTAssertEqualWithAccuracy(m.shimmerAlpha, 0.375, 0.0001);
        XCTAssertEqualWithAccuracy(m.fillAlpha, 0.85, 0.0001);
    }
}

// The row style has no shimmer at all: a 16pt gutter has no room for a sweep
// to read as motion rather than flicker. The waveform keeps its sweep.
- (void)testOnlyTheWaveformStyleSweeps {
    XCTAssertFalse(VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleRow, 16).hasShimmer);
    XCTAssertTrue(VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleWaveform, 480).hasShimmer);
}

// Each style has exactly one indeterminate motion: the waveform's is its
// sweep, the row's the whole-pill pulse — without one, indeterminate is
// pixel-identical to a determinate fill parked at zero, which reads as stuck.
// The pulse must peak above the resting track or it does not read at all.
- (void)testOnlyTheRowStylePulses {
    VibeLoadingIndicatorMetrics row =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertGreaterThan(row.pulseAlpha, row.trackAlpha);
    XCTAssertLessThanOrEqual(row.pulseAlpha, 1);
    XCTAssertEqual(VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleWaveform, 480).pulseAlpha, 0);
}

- (void)testRowFrontFadeFitsTheGutter {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertLessThan(m.frontFadePoints, 16);
}

// A capsule tall enough that the round ends actually read: cornerRadius is
// half the height, full pill ends, as layoutBars gives each EQ bar.
- (void)testRowStyleIsARoundEndedPill {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertEqual(m.height, 3);
    XCTAssertEqual(m.cornerRadius, m.height / 2);
}

@end
