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
    // 8 / 16 / 32 bars at 128 BPM.
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
    // Bars are a span of FILE time, which is what keeps a skip on the musical
    // grid whatever the varispeed rate is doing.
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
    // The stated distance is what the user reads off the time label, so the
    // file-time jump has to be scaled by the varispeed rate for the displayed
    // clock to advance by exactly that much.
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 0.0f, 10, 1.08), 10.8, 1e-9);
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, 0.0f, 10, 0.92), 9.2, 1e-9);
}

- (void)testNegativeTempoIsTreatedAsUnknown {
    // bpm is only ever 0-or-positive in practice; this pins that a garbage
    // value degrades to the fallback rather than producing a negative skip.
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(8, -120.0f, 10, 1.0), 10.0, 1e-9);
}

#pragma mark - Direction

- (void)testNegativeBarsSkipBackwardBySymmetricDistance {
    XCTAssertEqualWithAccuracy(VibeSkipFileSeconds(-8, 128.0f, 10, 1.0),
                               -VibeSkipFileSeconds(8, 128.0f, 10, 1.0), 1e-9);
}

@end
