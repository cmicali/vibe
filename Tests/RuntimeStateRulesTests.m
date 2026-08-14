//
// Pure state-machine seams used by runtime playback, granted-folder coverage
// and settings normalization.
//

#import <XCTest/XCTest.h>

#import "FolderAccessRules.h"
#import "PlaybackIntent.h"
#import "SettingsRules.h"

@interface RuntimeStateRulesTests : XCTestCase
@end

@implementation RuntimeStateRulesTests

- (void)testLoadingPauseIntentTogglesAndPreservesSeek {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(12.5, NO);
    XCTAssertTrue(VibePendingPlaybackIntentIsPlaying(intent));
    intent = VibePendingPlaybackIntentByTogglingPause(intent);
    XCTAssertTrue(intent.paused);
    XCTAssertEqualWithAccuracy(intent.position, 12.5, 0.001);
    intent = VibePendingPlaybackIntentBySeeking(intent, 42);
    XCTAssertTrue(intent.paused);
    XCTAssertEqualWithAccuracy(intent.position, 42, 0.001);
    intent = VibePendingPlaybackIntentByTogglingPause(intent);
    XCTAssertTrue(VibePendingPlaybackIntentIsPlaying(intent));
}

- (void)testLoadingSeekClampsNegativePositions {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(-10, NO);
    XCTAssertEqual(intent.position, 0);
    intent = VibePendingPlaybackIntentBySeeking(intent, -1);
    XCTAssertEqual(intent.position, 0);
}

- (void)testPitchRangeNormalizesToSupportedValues {
    XCTAssertEqual(VibeNormalizedPitchRange(8), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(16), 16);
    XCTAssertEqual(VibeNormalizedPitchRange(0), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(-16), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(32), 8);
}

#pragma mark - Granted-folder coverage

- (void)testFolderCoverageMatchesTheFolderAndItsDescendants {
    XCTAssertTrue(VibePathIsUnderFolder(@"/Volumes/Music", @"/Volumes/Music"));
    XCTAssertTrue(VibePathIsUnderFolder(@"/Volumes/Music/Set/a.mp3", @"/Volumes/Music"));
    // A sibling whose name merely starts the same is not covered.
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/Music2/a.mp3", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/Music", @""));
}

// The canonical form must NOT match a differently-cased spelling: on a
// case-sensitive volume those are genuinely different folders, and treating
// them as one would skip a bookmark the app needs.
- (void)testCanonicalFolderCoverageIsCaseSensitive {
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/music/a.mp3", @"/Volumes/Music"));
}

// The uncanonical form errs the other way, which is the safe direction: an
// open spelled differently by Launch Services still waits for the grant it
// probably needs.
- (void)testUncanonicalFolderCoverageIsCaseInsensitive {
    XCTAssertTrue(VibeUncanonicalPathIsUnderFolder(@"/Volumes/music/a.mp3", @"/Volumes/Music"));
    XCTAssertTrue(VibeUncanonicalPathIsUnderFolder(@"/VOLUMES/MUSIC", @"/Volumes/Music"));
    XCTAssertFalse(VibeUncanonicalPathIsUnderFolder(@"/Volumes/Music2/a.mp3", @"/Volumes/Music"));
    XCTAssertFalse(VibeUncanonicalPathIsUnderFolder(@"", @"/Volumes/Music"));
}

@end
