//
// Skip distances: bar-aligned when the tempo is known, pitch-compensated
// wall-clock when it isn't.
//

#import <XCTest/XCTest.h>

#import "TransportMath.h"

@interface TransportMathTests : XCTestCase
@end

@implementation TransportMathTests

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

@end
