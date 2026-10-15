// The snapshot's own arithmetic: the playhead the widget derives from it, and
// when the app publishes a new one.
// Nothing here reaches the app group container, which on the mac is a real
// directory under ~/Library.

#import <XCTest/XCTest.h>

#import "VibeWidgetState.h"

@interface VibeWidgetStateTests : XCTestCase
@end

@implementation VibeWidgetStateTests

- (VibeWidgetState *)stateAt:(NSTimeInterval)position playing:(BOOL)playing {
    VibeWidgetState *state = [[VibeWidgetState alloc] init];
    state.hasTrack = YES;
    state.playing = playing;
    state.duration = 100;
    state.position = position;
    state.positionDate = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
    return state;
}

- (NSDate *)at:(NSTimeInterval)seconds {
    return [NSDate dateWithTimeIntervalSinceReferenceDate:seconds];
}

- (void)testPlayingAdvancesFromThePublishedInstant {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    XCTAssertEqual([state positionAtDate:[self at:1015]], 25);
    XCTAssertEqual([state progressAtDate:[self at:1015]], 0.25);
}

- (void)testPausedHoldsItsPosition {
    XCTAssertEqual([[self stateAt:10 playing:NO] positionAtDate:[self at:1500]], 10);
}

- (void)testThePlayheadIsClampedToTheTrack {
    VibeWidgetState *state = [self stateAt:90 playing:YES];
    XCTAssertEqual([state positionAtDate:[self at:1500]], 100, @"never past the end");
    XCTAssertEqual([state progressAtDate:[self at:1500]], 1);
    XCTAssertEqual([state positionAtDate:[self at:900]], 90, @"a date before the publish adds nothing");
    XCTAssertEqual([[self stateAt:-5 playing:NO] positionAtDate:[self at:1000]], 0);
}

- (void)testNoDurationHasNoProgressAndNoUpperClamp {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.duration = 0;
    XCTAssertEqual([state progressAtDate:[self at:1100]], 0);
    XCTAssertEqual([state positionAtDate:[self at:1100]], 110);
}

- (void)testAPlayingSnapshotWithNoDateDoesNotAdvance {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.positionDate = nil;
    XCTAssertEqual([state positionAtDate:[self at:1100]], 10);
}

- (void)testASnapshotWithNoTrackKeyNamesNoImages {
    VibeWidgetState *state = [self stateAt:0 playing:NO];
    XCTAssertNil(state.artworkURL);
    XCTAssertNil(state.waveformPlayedURL);
    XCTAssertNil(state.waveformUnplayedURL);
}

#pragma mark - When to publish

- (VibeWidgetState *)published {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.title = @"Song";
    state.duration = 180;
    return state;
}

// The publisher's own call, with the last snapshot's fields unpacked.
static BOOL NeedsPublish(VibeWidgetState *_Nullable last, BOOL sameTrack, BOOL hasTrack, NSString *title,
                         NSString *_Nullable artist, BOOL playing, NSTimeInterval duration,
                         NSTimeInterval position, BOOL startPending, CFAbsoluteTime now) {
    return VibeWidgetNeedsPublish(last && sameTrack, last.hasTrack, last.title, last.artist, last.playing,
                                  last.duration, last.position, last.positionDate.timeIntervalSinceReferenceDate,
                                  hasTrack, title, artist, playing, duration, position, startPending, now);
}

- (void)testNothingPublishedOrANewTrackPublishes {
    XCTAssertTrue(NeedsPublish(nil, YES, YES, @"Song", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testSteadyPlaybackPublishesNothing {
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 40, NO, 1030),
                   @"the widget extrapolates the playhead");
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180.4, 11.9, NO, 1000),
                   @"within the tolerances");
}

- (void)testAPlayPauseALineOrADurationChangePublishes {
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, NO, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 181, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Tagged", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", @"Artist", YES, 180, 10, NO, 1000),
                  @"an artist landing");
    XCTAssertTrue(NeedsPublish(self.published, YES, NO, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testANilArtistEqualsANilArtist {
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 10, NO, 1000),
                   @"an artistless track would republish every tick");
}

- (void)testASeekPastTheToleranceRepublishesUnlessTheOpenRuns {
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 90, NO, 1000));
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 0, YES, 1000),
                   @"pinned at 0 while the open runs");
}

- (void)testAPausedSnapshotIsNotExtrapolated {
    VibeWidgetState *paused = self.published;
    paused.playing = NO;
    XCTAssertFalse(NeedsPublish(paused, YES, YES, @"Song", nil, NO, 180, 10, NO, 1060));
    XCTAssertTrue(NeedsPublish(paused, YES, YES, @"Song", nil, NO, 180, 15, NO, 1060));
}

@end
