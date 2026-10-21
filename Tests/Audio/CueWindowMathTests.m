//
// A cue window in CD frames, turned into a file's frames at its rate.
//

#import <XCTest/XCTest.h>

#import "CueWindowMath.h"

@interface CueWindowMathTests : XCTestCase
@end

@implementation CueWindowMathTests

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

// The end a voice stops reading at: rounded at the file's rate, and 0, the
// file's own end, for a window running to it.
- (void)testACueEndIsItsFrameAtTheFilesRate {
    XCTAssertEqual(VibeCueEndFrame(150, 44100), 88200);
    XCTAssertEqual(VibeCueEndFrame(7, 32000), 2987);
    XCTAssertEqual(VibeCueEndFrame(0, 48000), 0);
    XCTAssertEqual(VibeCueEndFrame(20, 32000), (int64_t)NSMaxRange(VibeCueWindow(7, 20, 32000, 10000000, NO)));
}

@end
