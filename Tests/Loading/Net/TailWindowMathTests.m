#import <XCTest/XCTest.h>

#import "TailWindowMath.h"

@interface TailWindowMathTests : XCTestCase
@end

@implementation TailWindowMathTests

// What each format's open reads at the end, with room: a small window for
// every head-and-trailer format, unknown ones too. A chunked container's
// window scales with the file between its floor and its cap: an MP4's moov,
// or a chunk after an AIFF's or a WAV's audio. None for a file no bigger than
// twice its window.
- (void)testTheTailWindowIsSizedPerFormat {
    const uint64_t KB = 1024, MB = 1024 * KB;
    for (NSString *extension in @[@"mp3", @"MP3", @"flac", @"ogg", @"opus", @"aac", @"mp2", @"xyz", @""]) {
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 300 * MB), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB + 1), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB), 0u, @"%@: at twice the window", extension);
    }
    XCTAssertEqual(VibeAudioFileTailWindowBytes(@"mp3", 0), 0u);
    for (NSString *extension in @[@"m4a", @"M4A", @"m4b", @"m4r", @"mp4", @"qta",
                                  @"aif", @"AIFF", @"aiff", @"wav", @"wave", @"bwf", @"w64", @"caf"]) {
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
        // The measured AIFF: 89,748,808 bytes, a 235 KB tag after its audio.
        XCTAssertGreaterThan(VibeAudioFileTailWindowBytes(extension, 89748808), 235 * KB + 8, @"%@", extension);
    }
}

@end
