#import <XCTest/XCTest.h>

#import "PlayerScreenRules.h"

@interface PlayerScreenRulesTests : XCTestCase
@end

@implementation PlayerScreenRulesTests

#pragma mark - The states

- (void)testNoTracksIsEmptyWhateverElseIsSet {
    XCTAssertEqual(VibeResolvePlayerScreenState(0, NO, NO, NO, 0), VibePlayerScreenStateEmpty);
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

// In both, the times must render at rest whatever the last attempt did.
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

#pragma mark - The mini player

- (void)testMiniPlayerStandsExactlyWhereThereIsATrackToName {
    XCTAssertTrue(VibeMiniPlayerVisible(VibePlayerScreenStateLoading));
    XCTAssertTrue(VibeMiniPlayerVisible(VibePlayerScreenStateParked));
    XCTAssertTrue(VibeMiniPlayerVisible(VibePlayerScreenStateTrack));
}

- (void)testMiniPlayerIsGoneWithTheEmptyPlaylistAndAfterAFailedPlay {
    // A strip naming audio that did not start is worse than no strip, which is
    // why Error is on this side and not with the three above.
    XCTAssertFalse(VibeMiniPlayerVisible(VibePlayerScreenStateEmpty));
    XCTAssertFalse(VibeMiniPlayerVisible(VibePlayerScreenStateError));
}

- (void)testMiniPlayerAgreesWithDescribesTrackInEveryState {
    VibePlayerScreenState states[] = {
        VibePlayerScreenStateEmpty, VibePlayerScreenStateLoading,
        VibePlayerScreenStateParked, VibePlayerScreenStateError,
        VibePlayerScreenStateTrack,
    };
    for (size_t i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
        XCTAssertEqual(VibeMiniPlayerVisible(states[i]),
                       VibePlayerScreenDescribesTrack(states[i]));
    }
}

@end
