//
// The five-state resolution every header render routes through. Its inputs
// are three track identities and three flags, so the whole state machine is
// enumerable without a window, a player or a playlist.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "TrackDisplayController.h"

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
    // A launch-time open may still be resolving; flashing the drop hint and
    // then replacing it a moment later is the thing being avoided.
    XCTAssertEqual(VibeResolveTrackDisplayState(nil, nil, nil, YES, YES, NO),
                   TrackDisplayStateLaunchGrace);
}

- (void)testLaunchGraceOutranksEveryPlayerFlag {
    // With no track there is nothing to render regardless of what the player
    // is doing, so the player flags must not leak into this branch.
    XCTAssertEqual(VibeResolveTrackDisplayState(nil, _otherTrack, _track, YES, NO, YES),
                   TrackDisplayStateLaunchGrace);
}

#pragma mark - Error

- (void)testErroredTrackOnAStoppedPlayerIsTheErrorState {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, nil, _track, NO, YES, NO),
                   TrackDisplayStateError);
}

- (void)testRetryingAnErroredTrackLiftsTheMaskImmediately {
    // Gated on stopped precisely so the retry's Loading/Playing state clears
    // the error text without waiting for anything else to reset it.
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
    // The change is queued on the player's serial queue: its currentTrack, and
    // so its position and duration, still describe the previous file. Showing
    // Track here would composite the new track's tags over the old file's
    // times.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, nil, NO, NO, NO),
                   TrackDisplayStateLoading);
}

- (void)testPlayerWithNoTrackYetRendersAsLoading {
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, nil, nil, NO, NO, NO),
                   TrackDisplayStateLoading);
}

- (void)testEndOfPlaylistParkIsNotTheGap {
    // A stopped player legitimately parks on the playlist's last track, which
    // is why the gap check excludes Stopped — otherwise the end of a playlist
    // would sit in a permanent Loading state.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _otherTrack, nil, NO, YES, NO),
                   TrackDisplayStateTrack);
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
    // Paused or stopped on the track it is actually on: still a normal header.
    XCTAssertEqual(VibeResolveTrackDisplayState(_track, _track, nil, NO, YES, NO),
                   TrackDisplayStateTrack);
}

#pragma mark - Precedence

- (void)testErrorOutranksTheTrackChangeGap {
    // Both conditions hold: the player is stopped on a different track AND
    // this track errored. Error wins, so a failed open shows its message
    // rather than a permanent spinner.
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

@end
