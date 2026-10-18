
#import <XCTest/XCTest.h>

#import "TransportMath.h"

@interface TransportMathTests : XCTestCase
@end

@implementation TransportMathTests

#pragma mark - The three distances

// Level 0, 1 and 2 double the base; an unset base of 0 reads 8.
- (void)testTheThreeLevelsDoubleTheBaseAndAnUnsetBaseReadsEight {
    XCTAssertEqual(VibeSkipBars(4, 0), 4);
    XCTAssertEqual(VibeSkipBars(4, 1), 8);
    XCTAssertEqual(VibeSkipBars(4, 2), 16);
    XCTAssertEqual(VibeSkipBars(16, 2), 64);
    XCTAssertEqual(VibeSkipBars(0, 0), 8);
    XCTAssertEqual(VibeSkipBars(0, 2), 32);
    XCTAssertEqualWithAccuracy(VibeSkipWallClockSeconds(0), 10.0, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipWallClockSeconds(1), 30.0, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipWallClockSeconds(2), 60.0, 1e-9);
}

#pragma mark - Bar-aligned

- (void)testOneBarAtOneTwentyIsTwoSeconds {
    // 120 BPM = 2 beats/sec, a bar is 4 beats.
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(1, 120.0f, 10, 1.0), 2.0, 1e-9);
}

- (void)testTheThreeSkipDistancesScaleWithBars {
    double perBar = 4.0 * 60.0 / 128.0;
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 128.0f, 10, 1.0), 8 * perBar, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(16, 128.0f, 30, 1.0), 16 * perBar, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(32, 128.0f, 60, 1.0), 32 * perBar, 1e-9);
}

- (void)testSlowerTempoMeansALongerBar {
    XCTAssertGreaterThan(VibeSkipFileSeconds(8, 85.0f, 10, 1.0),
                         VibeSkipFileSeconds(8, 174.0f, 10, 1.0));
}

- (void)testBarDistanceIgnoresPitch {
    // Bars are file time, which keeps a skip on the grid at any varispeed rate.
    double atRest = VibeSkipFileSeconds(8, 128.0f, 10, 1.0);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 128.0f, 10, 1.08), atRest, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 128.0f, 10, 0.92), atRest, 1e-9);
}

- (void)testBarDistanceIgnoresTheWallClockFallback {
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 128.0f, 10, 1.0),
                               VibeSkipFileSeconds(8, 128.0f, 9999, 1.0), 1e-9);
}

#pragma mark - Wall-clock fallback

- (void)testUnknownTempoFallsBackToWallClockSeconds {
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 0.0f, 10, 1.0), 10.0, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(16, 0.0f, 30, 1.0), 30.0, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(32, 0.0f, 60, 1.0), 60.0, 1e-9);
}

- (void)testFallbackIsConvertedToFileTimeByTheRate {
    // The stated distance is read off the time label, so the file-time jump is
    // scaled by the rate for the displayed clock to move by exactly that much.
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 0.0f, 10, 1.08), 10.8, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 0.0f, 10, 0.92), 9.2, 1e-9);
}

- (void)testNegativeTempoIsTreatedAsUnknown {
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, -120.0f, 10, 1.0), 10.0, 1e-9);
}

#pragma mark - Direction

- (void)testNegativeBarsSkipBackwardBySymmetricDistance {
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(-8, 128.0f, 10, 1.0),
                               -VibeSkipFileSeconds(8, 128.0f, 10, 1.0), 1e-9);
}

#pragma mark - Volume scroll

- (void)testAWheelLineAndTenTrackpadPointsAreOneStep {
    XCTAssertEqualWithAccuracy(VibeVolumeScrollDelta(1, NO, NO), kVibeVolumeStep, 1e-9);
    XCTAssertEqualWithAccuracy(VibeVolumeScrollDelta(10, YES, NO), kVibeVolumeStep, 1e-9);
    XCTAssertEqualWithAccuracy(VibeVolumeScrollDelta(3, YES, NO), 0.015, 1e-9);
}

// Natural scrolling flips the delta's sign, and the volume follows the
// fingers, not the content.
- (void)testUpIsLouderUnderEitherScrollingDirection {
    XCTAssertGreaterThan(VibeVolumeScrollDelta(4, YES, NO), 0);
    XCTAssertGreaterThan(VibeVolumeScrollDelta(-4, YES, YES), 0);
    XCTAssertLessThan(VibeVolumeScrollDelta(-1, NO, NO), 0);
    XCTAssertLessThan(VibeVolumeScrollDelta(1, NO, YES), 0);
}

@end
