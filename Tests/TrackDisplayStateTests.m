//
// The five-state resolution every header render routes through. Its inputs
// are three track identities and three flags, so the whole state machine is
// enumerable without a window, a player or a playlist.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "TrackDisplayRules.h"

@interface TrackDisplayStateTests : XCTestCase
@end

@implementation TrackDisplayStateTests {
    AudioTrack *_track;
    AudioTrack *_otherTrack;
}

- (void)setUp {
    // Only identity matters to the resolver; it never messages these.
    _track = [AudioTrack withURL:[NSURL fileURLWithPath:@"/private/tmp/a.mp3"]];
    _otherTrack = [AudioTrack withURL:[NSURL fileURLWithPath:@"/private/tmp/b.mp3"]];
}

#pragma mark - No track

- (void)testNoTrackIsTheEmptyState {
    XCTAssertEqual(VibeResolveTrackDisplayState(nil, nil, nil, NO, YES, NO),
                   TrackDisplayStateEmpty);
}

- (void)testNoTrackDuringLaunchGraceIsBlankNotEmpty {
    // A launch-time open may still be resolving; the drop hint must not flash.
    XCTAssertEqual(VibeResolveTrackDisplayState(nil, nil, nil, YES, YES, NO),
                   TrackDisplayStateLaunchGrace);
}

- (void)testLaunchGraceOutranksEveryPlayerFlag {
    XCTAssertEqual(VibeResolveTrackDisplayState(nil, _otherTrack, _track, YES, NO, YES),
                   TrackDisplayStateLaunchGrace);
}

#pragma mark - Error

- (void)testErroredTrackOnAStoppedPlayerIsTheErrorState {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, nil, _track, NO, YES, NO),
                   TrackDisplayStateError);
}

- (void)testRetryingAnErroredTrackLiftsTheMaskImmediately {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, _track, NO, NO, YES),
                   TrackDisplayStateLoading);
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, _track, NO, NO, NO),
                   TrackDisplayStateTrack);
}

- (void)testAnErrorOnSomeOtherTrackDoesNotMaskThisOne {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, _otherTrack, NO, YES, NO),
                   TrackDisplayStateTrack);
}

#pragma mark - The track-change gap

- (void)testPlayerStillOnThePreviousTrackRendersAsLoading {
    // The player's position and duration still describe the previous file;
    // Track here would composite the new tags over the old times.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, nil, NO, NO, NO),
                   TrackDisplayStateLoading);
}

- (void)testPlayerWithNoTrackYetRendersAsLoading {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, nil, nil, NO, NO, NO),
                   TrackDisplayStateLoading);
}

- (void)testEndOfPlaylistParkIsNotTheGap {
    // An idle player parks on the track it just finished, so the park has
    // playerTrack == currentTrack and needs no Stopped exemption.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, nil, NO, YES, NO),
                   TrackDisplayStateTrack);
}

- (void)testTrackChangeFromTheStoppedParkIsTheGap {
    // The playlist notifies synchronously while play flips the player's state
    // on its serial queue, so the player still reads Stopped on the old track.
    // Exempting Stopped would render, and publish to Now Playing, the new tags
    // with the finished file's times.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, nil, NO, YES, NO),
                   TrackDisplayStateLoading);
}

- (void)testStoppedPlayerWithNoTrackOpenIsTheGap {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, nil, nil, NO, YES, NO),
                   TrackDisplayStateLoading);
}

#pragma mark - Loading and Track

- (void)testInFlightOpenOfTheCurrentTrackIsLoading {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, nil, NO, NO, YES),
                   TrackDisplayStateLoading);
}

- (void)testSettledPlaybackIsTheTrackState {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, nil, NO, NO, NO),
                   TrackDisplayStateTrack);
}

- (void)testStoppedOnTheCurrentTrackIsTheTrackState {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, nil, NO, YES, NO),
                   TrackDisplayStateTrack);
}

#pragma mark - Precedence

- (void)testErrorOutranksTheTrackChangeGap {
    // So a failed open shows its message rather than a permanent spinner.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, _track, NO, YES, NO),
                   TrackDisplayStateError);
}

- (void)testTheGapOutranksThePlayerLoadingFlag {
    // Both would render Loading, so this pins the ordering rather than the
    // outcome — the gap is detected before isLoading is consulted.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, nil, NO, NO, YES),
                   TrackDisplayStateLoading);
}

- (void)testEveryInputCombinationResolvesToARealState {
    // No combination of flags may fall through: a garbage enum value would
    // silently take whichever render branch it happened to match.
    NSArray *tracks = @[[NSNull null], _track, _otherTrack];
    for (id current in tracks) {
        for (id player in tracks) {
            for (id errored in tracks) {
                for (int flags = 0; flags < 8; flags++) {
                    TrackDisplayState state = VibeResolveTrackDisplayState(
                            current == [NSNull null] ? nil : current,
                            player == [NSNull null] ? nil : player,
                            errored == [NSNull null] ? nil : errored,
                            (flags & 1) != 0, (flags & 2) != 0, (flags & 4) != 0);
                    XCTAssertTrue(state == TrackDisplayStateTrack ||
                                  state == TrackDisplayStateLoading ||
                                  state == TrackDisplayStateEmpty ||
                                  state == TrackDisplayStateLaunchGrace ||
                                  state == TrackDisplayStateError,
                                  @"unresolved state %ld", (long)state);
                }
            }
        }
    }
}


- (void)testTimeTicksCannotOverwritePlaceholderStates {
    for (NSNumber *state in @[@(TrackDisplayStateLoading), @(TrackDisplayStateEmpty),
                             @(TrackDisplayStateLaunchGrace), @(TrackDisplayStateError)]) {
        XCTAssertFalse(VibeTrackTimeMayUpdate(state.integerValue, 120, NO));
        XCTAssertFalse(VibeTrackTimeMayUpdate(state.integerValue, 120, YES));
    }
}

- (void)testParkedTrackMayResetElapsedWithoutOverwritingItsFullDuration {
    for (NSNumber *duration in @[@0, @(-1), @(NAN)]) {
        XCTAssertTrue(VibeTrackTimeMayUpdate(TrackDisplayStateTrack, duration.doubleValue, NO));
        XCTAssertFalse(VibeTrackTimeMayUpdate(TrackDisplayStateTrack, duration.doubleValue, YES));
    }
    XCTAssertTrue(VibeTrackTimeMayUpdate(TrackDisplayStateTrack, 120, YES));
}

@end
