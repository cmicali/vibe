//
// The iOS player screen's display-state resolution. Its inputs are a count,
// three flags and a duration, so the whole state machine is enumerable without
// a view, a player or a playlist.
//

#import <XCTest/XCTest.h>

#import "PlayerScreenRules.h"

@interface PlayerScreenRulesTests : XCTestCase
@end

@implementation PlayerScreenRulesTests

#pragma mark - The states

- (void)testNoTracksIsEmptyWhateverElseIsSet {
    XCTAssertEqual(VibeResolvePlayerScreenState(0, NO, NO, NO, 0), VibePlayerScreenStateEmpty);
    // Empty wins over every other flag: with no tracks there is nothing for
    // them to describe.
    XCTAssertEqual(VibeResolvePlayerScreenState(0, YES, YES, YES, 120), VibePlayerScreenStateEmpty);
}

- (void)testPendingStartIsLoading {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, YES, NO, NO, 0), VibePlayerScreenStateLoading);
    // The player's duration still describes the OUTGOING track during the gap,
    // so a nonzero one must not promote this to Track.
    XCTAssertEqual(VibeResolvePlayerScreenState(3, YES, NO, NO, 240), VibePlayerScreenStateLoading);
}

- (void)testParkedWithNothingOpenIsParked {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, NO, YES, NO, 0), VibePlayerScreenStateParked);
}

// The end-of-playlist park leaves the finished file open, so the duration is
// still real and the live times stay correct.
- (void)testParkedWithAnOpenFileIsTrack {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, NO, YES, NO, 240), VibePlayerScreenStateTrack);
}

- (void)testFailedPlayIsError {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, NO, NO, YES, 0), VibePlayerScreenStateError);
}

- (void)testLivePlayheadIsTrack {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, NO, NO, NO, 240), VibePlayerScreenStateTrack);
}

#pragma mark - Precedence

// The two "the player is holding nothing usable" states outrank Error,
// because in both the times must render at rest whatever the last attempt
// did. A failure landing on a parked track keeps the park's resting times.
- (void)testRestingStatesOutrankError {
    XCTAssertEqual(VibeResolvePlayerScreenState(3, YES, NO, YES, 0), VibePlayerScreenStateLoading);
    XCTAssertEqual(VibeResolvePlayerScreenState(3, NO, YES, YES, 0), VibePlayerScreenStateParked);
}

- (void)testPendingOutranksParked {
    // playCurrentTrack clears parked before it sets pending, but the rule must
    // not depend on that ordering.
    XCTAssertEqual(VibeResolvePlayerScreenState(3, YES, YES, NO, 0), VibePlayerScreenStateLoading);
}

#pragma mark - The derived questions

- (void)testOnlyLoadingAndParkedRenderRestingTimes {
    XCTAssertTrue(VibePlayerScreenRendersRestingTimes(VibePlayerScreenStateLoading));
    XCTAssertTrue(VibePlayerScreenRendersRestingTimes(VibePlayerScreenStateParked));
    XCTAssertFalse(VibePlayerScreenRendersRestingTimes(VibePlayerScreenStateTrack));
    XCTAssertFalse(VibePlayerScreenRendersRestingTimes(VibePlayerScreenStateEmpty));
    XCTAssertFalse(VibePlayerScreenRendersRestingTimes(VibePlayerScreenStateError));
}

- (void)testEmptyAndErrorDescribeNoTrack {
    XCTAssertFalse(VibePlayerScreenDescribesTrack(VibePlayerScreenStateEmpty));
    XCTAssertFalse(VibePlayerScreenDescribesTrack(VibePlayerScreenStateError));
    XCTAssertTrue(VibePlayerScreenDescribesTrack(VibePlayerScreenStateLoading));
    XCTAssertTrue(VibePlayerScreenDescribesTrack(VibePlayerScreenStateParked));
    XCTAssertTrue(VibePlayerScreenDescribesTrack(VibePlayerScreenStateTrack));
}

@end
