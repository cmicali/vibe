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

// The 40pt-floor trap: at the 16pt gutter the waveform's minimum band width
// clamps to the full width and the sweep animates a full-width block with no
// visible motion. The row band must always have room to travel.
- (void)testRowBandIsNarrowerThanTheGutter {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertLessThan(m.bandWidth, 16);
}

- (void)testRowFrontFadeFitsTheGutter {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertLessThan(m.frontFadePoints, 16);
}

// One EQ bar's weight with pill ends, exactly as layoutBars gives each bar:
// (16 - 4 * 1.5) / 5 = 2 tall, cornerRadius half the height.
- (void)testRowStyleIsAnEqualizerBarWeightPill {
    VibeLoadingIndicatorMetrics m =
            VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16);
    XCTAssertEqual(m.height, 2);
    XCTAssertEqual(m.cornerRadius, m.height / 2);
}

@end
