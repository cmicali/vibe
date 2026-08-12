//
// Gapless auto-advance: the splice arithmetic and its arming gates.
//

#import <XCTest/XCTest.h>

#import "GaplessSpliceMath.h"

@interface GaplessSpliceMathTests : XCTestCase
@end

@implementation GaplessSpliceMathTests

#pragma mark - Arming gates

- (void)testDeclickMinimumAllowsArming {
    XCTAssertTrue(VibeGaplessArmAllowed(10));
    XCTAssertTrue(VibeGaplessArmAllowed(0));
}

- (void)testCrossfadeSettingsBlockArming {
    XCTAssertFalse(VibeGaplessArmAllowed(500));
    XCTAssertFalse(VibeGaplessArmAllowed(2000));
}

- (void)testFormatsMatchRequiresExactRateAndChannels {
    XCTAssertTrue(VibeGaplessFormatsMatch(44100, 2, 44100, 2));
    XCTAssertFalse(VibeGaplessFormatsMatch(44100, 2, 48000, 2));
    XCTAssertFalse(VibeGaplessFormatsMatch(44100, 2, 44100, 1));
}

#pragma mark - Promoted segment start

- (void)testPromotedStartShiftsBackByFinishedLength {
    // Track played from its start: the promoted start is minus its length.
    XCTAssertEqual(VibeGaplessPromotedSegmentStart(0, 1000000), -1000000);
    // Track entered via a seek: the positive start composes the same way.
    XCTAssertEqual(VibeGaplessPromotedSegmentStart(44100, 1000000), -955900);
}

// Within one node run, position_frames = segmentStart + sampleTime. Across a
// promotion sampleTime keeps counting, so the same sampleTime must map to the
// new track's timeline exactly length(finished) frames earlier.
- (void)testPositionIsContinuousAcrossThePromotion {
    int64_t segStart = 44100;   // track N was seeked into at 1 s
    int64_t lengthN = 5 * 44100;
    // The boundary passes when sampleTime reaches the frames N had left.
    int64_t boundarySampleTime = lengthN - segStart;
    int64_t promotedStart = VibeGaplessPromotedSegmentStart(segStart, lengthN);
    // One frame before the boundary: last frame of N.
    XCTAssertEqual(segStart + (boundarySampleTime - 1), lengthN - 1);
    // At the boundary, the promoted mapping reads frame 0 of N+1.
    XCTAssertEqual(promotedStart + boundarySampleTime, 0);
    // And one second in, one second of N+1.
    XCTAssertEqual(promotedStart + boundarySampleTime + 44100, 44100);
}

// A second promotion composes: the start only ever shifts further back.
- (void)testChainedPromotionsCompose {
    int64_t lengthN = 300 * 44100;
    int64_t lengthN1 = 200 * 44100;
    int64_t startN1 = VibeGaplessPromotedSegmentStart(0, lengthN);
    int64_t startN2 = VibeGaplessPromotedSegmentStart(startN1, lengthN1);
    XCTAssertEqual(startN2, -(lengthN + lengthN1));
    // sampleTime at N+2's boundary is the total frames rendered so far.
    XCTAssertEqual(startN2 + (lengthN + lengthN1), 0);
}

@end
