//
// Standardized-path identity for bounded audio-open claims, the
// delivery/detach race, and the tail a stream fetches ahead.
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenRules.h"

@interface AudioFileOpenRulesTests : XCTestCase
@end

@implementation AudioFileOpenRulesTests

- (void)testEquivalentFilePathsShareOneClaimSpelling {
    NSURL *direct = [NSURL fileURLWithPath:@"/tmp/vibe/audio.flac"];
    NSURL *lexicalAlias = [NSURL fileURLWithPath:@"/tmp/vibe/part/../audio.flac"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(direct),
                          VibeStandardizedAudioOpenPath(lexicalAlias));
}

- (void)testNonFileURLUsesItsAbsoluteIdentity {
    NSURL *url = [NSURL URLWithString:@"https://example.com/audio.flac?take=2"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), url.absoluteString);
}

- (void)testDetachWinsBeforeQueuedDeliveryBegins {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryDetached);
}

- (void)testDeliveryAlreadyRunningCannotBeRetracted {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryRunning);
}

// What each format's open reads at the end, with room: a small window for
// every head-and-trailer format, unknown ones too; an MP4's moov scaled with
// the file between its floor and its cap; none for a file no bigger than twice
// its window.
- (void)testTheTailWindowIsSizedPerFormat {
    const uint64_t KB = 1024, MB = 1024 * KB;
    for (NSString *extension in @[@"mp3", @"MP3", @"flac", @"wav", @"aiff", @"aif", @"w64", @"caf", @"ogg", @"xyz", @""]) {
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 300 * MB), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB + 1), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB), 0u, @"%@: at twice the window", extension);
    }
    XCTAssertEqual(VibeAudioFileTailWindowBytes(@"mp3", 0), 0u);
    for (NSString *extension in @[@"m4a", @"M4A", @"m4b", @"m4r", @"mp4", @"qta"]) {
        // 6 minutes of 256 kbps AAC, its moov ~60 KB: the floor.
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 11 * MB), 512 * KB, @"%@", extension);
        // A 32nd of the file between the two.
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 32 * MB), 1 * MB, @"%@", extension);
        // An hour of 128 kbps (57 MB, moov 608 KB) and a two-hour mix (moov
        // ~1.2 MB) both fit under the cap, 1.5 MB, reached from 48 MB.
        XCTAssertGreaterThan(VibeAudioFileTailWindowBytes(extension, 57 * MB), 2 * 608 * KB, @"%@", extension);
        XCTAssertGreaterThan(VibeAudioFileTailWindowBytes(extension, 115 * MB), 120 * 10 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 48 * MB), 1536 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 300 * MB), 1536 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 1 * MB + 1), 512 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 1 * MB), 0u, @"%@: at twice the floor", extension);
    }
}

@end
