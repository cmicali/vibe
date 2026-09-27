//
// The in-flight open's pending intent: whether the opening file lands playing
// or parked, and where. A play/pause tap or a seek during Loading edits it
// rather than being dropped.
//

#import <XCTest/XCTest.h>

#import "PlaybackIntent.h"

@interface PlaybackIntentTests : XCTestCase
@end

@implementation PlaybackIntentTests

- (void)testLoadingPauseIntentTogglesAndPreservesSeek {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(12.5, NO);
    XCTAssertFalse(intent.paused);
    intent = VibePendingPlaybackIntentByTogglingPause(intent);
    XCTAssertTrue(intent.paused);
    XCTAssertEqualWithAccuracy(intent.position, 12.5, 0.001);
    intent = VibePendingPlaybackIntentBySeeking(intent, 42);
    XCTAssertTrue(intent.paused);
    XCTAssertEqualWithAccuracy(intent.position, 42, 0.001);
    intent = VibePendingPlaybackIntentByTogglingPause(intent);
    XCTAssertFalse(intent.paused);
}

- (void)testLoadingSeekClampsNegativePositions {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(-10, NO);
    XCTAssertEqual(intent.position, 0);
    intent = VibePendingPlaybackIntentBySeeking(intent, -1);
    XCTAssertEqual(intent.position, 0);
}

@end
