#import <XCTest/XCTest.h>

#import "NetworkReadAheadMath.h"

@interface NetworkReadAheadMathTests : XCTestCase
@end

@implementation NetworkReadAheadMathTests

// A play's read-ahead: 30 s at the file's byte rate, between 8 MB and 64 MB.
// A file with no duration keeps the floor.
- (void)testTheReadAheadSpanIsThirtySecondsBetweenItsFloorAndCap {
    const uint64_t MB = 1024 * 1024;
    XCTAssertEqual(kVibeReadAheadFloorBytes, 8 * MB);
    // Five minutes of a 24/192 stereo WAV, 1,152,000 bytes a second.
    XCTAssertEqual(VibeReadAheadSpanBytes(300 * 1152000ull, 300), 30 * 1152000ull);
    // Five minutes of a 320k MP3: 1.2 MB in 30 s, raised to the floor.
    XCTAssertEqual(VibeReadAheadSpanBytes(300 * 40000ull, 300), 8 * MB);
    // Eight channels of 32-bit at 192 kHz: past the cap.
    XCTAssertEqual(VibeReadAheadSpanBytes(300 * 6144000ull, 300), 64 * MB);
    XCTAssertEqual(VibeReadAheadSpanBytes(UINT64_MAX, 1e-9), 64 * MB);
    // No duration.
    for (NSNumber *seconds in @[@0, @-1, @(NAN)]) {
        XCTAssertEqual(VibeReadAheadSpanBytes(300 * 1152000ull, seconds.doubleValue), 8 * MB, @"%@", seconds);
    }
    XCTAssertEqual(VibeReadAheadSpanBytes(0, 300), 8 * MB);
}

@end
