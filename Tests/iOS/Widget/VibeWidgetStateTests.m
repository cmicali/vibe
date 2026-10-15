// The snapshot's own arithmetic: the playhead the widget derives from it.
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

@end
