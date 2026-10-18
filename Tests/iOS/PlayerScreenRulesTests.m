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

#pragma mark - Duration and a scrub

- (void)testTheScreensDrawThePlayersDurationElseTheMetadatas {
    XCTAssertEqual(VibePlayerScreenDuration(200, 180), 200);
    XCTAssertEqual(VibePlayerScreenDuration(0, 180), 180);
    XCTAssertEqual(VibePlayerScreenDuration(0, 0), 0);
}

- (void)testAScrubWithAPlayerDurationSeeksThePlayer {
    XCTAssertEqual(VibePlayerScrubActionFor(200, YES, NO, NO, 0), VibePlayerScrubActionSeekPlayer);
    XCTAssertEqual(VibePlayerScrubActionFor(200, NO, NO, NO, 0), VibePlayerScrubActionSeekPlayer);
}

- (void)testAScrubOnAParkedTrackOpensItPausedNeverPlays {
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, YES, NO, 180), VibePlayerScrubActionOpenParked);
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, YES, YES, 180), VibePlayerScrubActionOpenParked,
                   @"a second scrub rebinds the parked open");
}

- (void)testAScrubBeforeTheMetadataHoldsItsTarget {
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, YES, NO, 0), VibePlayerScrubActionHold);
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, NO, YES, 0), VibePlayerScrubActionHold);
}

- (void)testAScrubIntoAnOpenSeeksByTheMetadata {
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, NO, YES, 180), VibePlayerScrubActionSeekPlayer);
}

- (void)testAScrubWithNothingToSeekIsIgnored {
    XCTAssertEqual(VibePlayerScrubActionFor(0, NO, YES, YES, 180), VibePlayerScrubActionIgnore);
    XCTAssertEqual(VibePlayerScrubActionFor(0, YES, NO, NO, 180), VibePlayerScrubActionIgnore,
                   @"stopped, with no open to seek into");
}

#pragma mark - The playhead

// A player stepping 23 ms every third 60 Hz frame, read every frame: the shown
// position moves the same amount each frame, where the player's jumps.
- (void)testTheShownPlayheadMovesEvenlyBetweenThePlayersSteps {
    double frame = 1.0 / 60, buffer = 1024.0 / 44100;
    NSTimeInterval shown = -1, lastShown = 0;
    double smallest = INFINITY, largest = 0;
    for (int i = 0; i < 600; i++) {
        double now = 10 + i * frame;
        NSTimeInterval player = floor(now / buffer) * buffer;
        shown = VibePlayheadShownPosition(shown, i == 0 ? 0 : frame, player);
        if (i > 300) {
            smallest = fmin(smallest, shown - lastShown);
            largest = fmax(largest, shown - lastShown);
            XCTAssertEqualWithAccuracy(shown, player, buffer, @"it follows the player");
        }
        lastShown = shown;
    }
    XCTAssertGreaterThan(smallest, frame * 0.8);
    XCTAssertLessThan(largest, frame * 1.2, @"the player's own steps are 0 or 23 ms");
}

- (void)testTheShownPlayheadJumpsToASeek {
    XCTAssertEqual(VibePlayheadShownPosition(-1, 0.016, 42), 42, @"a first frame takes the player's");
    XCTAssertEqual(VibePlayheadShownPosition(10, 0.016, 90), 90);
    XCTAssertEqual(VibePlayheadShownPosition(10, 0.016, 9), 9, @"back as well as forward");
    XCTAssertEqualWithAccuracy(VibePlayheadShownPosition(10, 0.016, 10.016), 10.016, 1e-9);
}

#pragma mark - The pager

- (void)testNextDimsOnlyOnTheLastPageUnlessRepeatAll {
    XCTAssertTrue(VibePlayerPageNextEnabled(1, 0, 3, NO, NO));
    XCTAssertFalse(VibePlayerPageNextEnabled(2, 0, 3, YES, NO), @"the last page arrives dimmed");
    XCTAssertTrue(VibePlayerPageNextEnabled(2, 0, 3, NO, YES), @"under Repeat All no page is last");
}

- (void)testTheCurrentPageAsksThePlaylist {
    XCTAssertFalse(VibePlayerPageNextEnabled(1, 1, 3, NO, NO), @"under shuffle only the playlist knows");
    XCTAssertTrue(VibePlayerPageNextEnabled(2, 2, 3, YES, NO));
}

- (void)testThePageWindowIsClampedToThePlaylist {
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(0, 0, 2), NSMakeRange(0, 0)));
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(10, 5, 2), NSMakeRange(3, 5)));
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(10, 0, 2), NSMakeRange(0, 3)));
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(10, 9, 1), NSMakeRange(8, 2)));
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(1, 0, 1), NSMakeRange(0, 1)));
    XCTAssertTrue(NSEqualRanges(VibePlayerPageWindow(4, NSNotFound, 1), NSMakeRange(2, 2)),
                  @"a cursor past the end counts as the last page");
}

@end
