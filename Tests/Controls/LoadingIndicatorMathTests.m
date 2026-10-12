//
//  LoadingIndicatorMathTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "LoadingIndicatorMath.h"

@interface LoadingIndicatorMathTests : XCTestCase
@end

@implementation LoadingIndicatorMathTests

// Pinned exactly: the track matches the unplayed waveform's brightness, and the
// macOS empty-state line reads its height and alpha from here.
- (void)testWaveformStyleMetricsArePinned {
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

// A 16pt gutter has no room for a sweep to read as motion rather than flicker.
- (void)testOnlyTheWaveformStyleSweeps {
    XCTAssertFalse(VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleRow, 16).hasShimmer);
    XCTAssertTrue(VibeLoadingIndicatorMetricsForStyle(
            VibeLoadingIndicatorStyleWaveform, 480).hasShimmer);
}

// Each style has exactly one indeterminate motion; without one, indeterminate
// looks like a determinate fill stuck at zero. The pulse must peak above the
// resting track to read at all.
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

// Tall enough that the round ends read; full pill ends, like each EQ bar's.
- (void)testRowStyleIsARoundEndedPill {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertEqual(m.height, 3);
    XCTAssertEqual(m.cornerRadius, m.height / 2);
}

@end
