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

#pragma mark - Windows

// 588 and 640 file frames per CD frame: exact.
- (void)testACueWindowIsExactAt44100And48000 {
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(75, 150, 44100, 10000000, NO), NSMakeRange(44100, 44100)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(30, 105, 48000, 10000000, NO), NSMakeRange(19200, 48000)));
}

// 426.67 frames per CD frame: both rows round the marker they share alike, so
// they stay contiguous.
- (void)testContiguousWindowsStayContiguousAtARate75DoesNotDivide {
    NSRange first = VibeCueWindow(0, 7, 32000, 10000000, NO);
    NSRange second = VibeCueWindow(7, 20, 32000, 10000000, NO);
    XCTAssertEqual(NSMaxRange(first), second.location);
    XCTAssertEqual(second.location, 2987u);
}

- (void)testAnEndOfZeroOrPastTheFileIsTheFilesEnd {
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(0, 0, 48000, 96000, NO), NSMakeRange(0, 96000)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(75, 0, 48000, 96000, NO), NSMakeRange(48000, 48000)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(75, 750, 48000, 96000, NO), NSMakeRange(48000, 48000)));
}

- (void)testAWindowWithNothingLeftIsEmpty {
    XCTAssertEqual(VibeCueWindow(150, 0, 48000, 96000, NO).length, 0u);
    XCTAssertEqual(VibeCueWindow(300, 0, 48000, 96000, NO).length, 0u);
    XCTAssertEqual(VibeCueWindow(0, 0, 48000, 0, NO).length, 0u);
}

// An estimate is not the end: a window past it is neither refused nor cut
// short, a cue end standing and a window to the file's end reaching a frame
// past its start; a window inside it is as exact as ever.
- (void)testAWindowPastAnEstimatedLengthIsKept {
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(150, 225, 48000, 96000, YES), NSMakeRange(96000, 48000)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(150, 0, 48000, 96000, YES), NSMakeRange(96000, 1)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(300, 0, 48000, 96000, YES), NSMakeRange(192000, 1)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(75, 750, 48000, 96000, YES), NSMakeRange(48000, 432000)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(75, 0, 48000, 96000, YES), NSMakeRange(48000, 48000)));
    XCTAssertTrue(NSEqualRanges(VibeCueWindow(30, 105, 48000, 96000, YES), NSMakeRange(19200, 48000)));
}

- (void)testAStartIsClampedInsideItsWindow {
    NSRange window = NSMakeRange(48000, 24000);
    XCTAssertEqual(VibeClampedStartFrame(0, 48000, window), 48000);
    XCTAssertEqual(VibeClampedStartFrame(0.25, 48000, window), 60000);
    XCTAssertEqual(VibeClampedStartFrame(-3, 48000, window), 48000);
    XCTAssertEqual(VibeClampedStartFrame(9, 48000, window), 71999, @"past the end lands on the last frame");
}

@end
