//
// AudioPlayer segment chunking at AVAudioFrameCount's uint32_t boundary.
//

#import <XCTest/XCTest.h>

#import "AudioScheduleMath.h"

@interface AudioScheduleMathTests : XCTestCase
@end

@implementation AudioScheduleMathTests

- (void)testSingleChunkAtFrameCountLimit {
    uint64_t frames = UINT32_MAX;
    XCTAssertEqual(VibeAudioScheduleChunkFrames(frames), UINT32_MAX);
}

- (void)testOneFramePastLimitNeedsASecondFinalChunk {
    uint64_t frames = (uint64_t)UINT32_MAX + 1;
    AVAudioFrameCount first = VibeAudioScheduleChunkFrames(frames);
    frames -= first;
    XCTAssertEqual(first, UINT32_MAX);
    XCTAssertEqual(frames, 1u);
    XCTAssertEqual(VibeAudioScheduleChunkFrames(frames), 1u);
}

- (void)testManyChunksCoverTheRemainderWithoutNarrowing {
    uint64_t expected = (uint64_t)UINT32_MAX * 2 + 1234;
    uint64_t remaining = expected;
    uint64_t scheduled = 0;
    uint64_t chunks = 0;
    while (remaining > 0) {
        AVAudioFrameCount next = VibeAudioScheduleChunkFrames(remaining);
        XCTAssertGreaterThan(next, 0u);
        scheduled += next;
        remaining -= next;
        chunks++;
    }
    XCTAssertEqual(scheduled, expected);
    XCTAssertEqual(chunks, 3u);
}

- (void)testFrameRemainderIsAtLeastOne {
    XCTAssertEqual(VibeAudioFramesToSchedule(100, 99), 1u);
    XCTAssertEqual(VibeAudioFramesToSchedule(100, 100), 1u);
    XCTAssertEqual(VibeAudioFramesToSchedule(100, 120), 1u);
    XCTAssertEqual(VibeAudioFramesToSchedule((AVAudioFramePosition)UINT32_MAX + 8, 4),
            (uint64_t)UINT32_MAX + 4);
}

@end
