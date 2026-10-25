//
// How a shell's transport reads the player.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "PlaybackShellRules.h"

@interface PlaybackShellRulesTests : XCTestCase
@end

@implementation PlaybackShellRulesTests

// On the first row, Previous restarts a loaded track. With nothing loaded
// there is nothing to restart, even before an asynchronous stop lands.
- (void)testPreviousIsAvailableOnTheFirstRowOnlyWithATrackLoaded {
    XCTAssertTrue(VibePlaybackPreviousIsAvailable(YES, YES, YES));
    XCTAssertTrue(VibePlaybackPreviousIsAvailable(YES, YES, NO));
    XCTAssertTrue(VibePlaybackPreviousIsAvailable(NO, YES, NO));
    XCTAssertFalse(VibePlaybackPreviousIsAvailable(NO, YES, YES));
    XCTAssertFalse(VibePlaybackPreviousIsAvailable(NO, NO, NO), @"a close whose stop has not landed");
}

- (void)testSeekSettlementMatchesRowsAndAcceptsEmptyOnlyWhileStopped {
    NSURL *url = [NSURL fileURLWithPath:@"/same.wav"];
    AudioTrack *track = [AudioTrack withURL:url], *otherRow = [AudioTrack withURL:url];
    for (NSNumber *stopped in @[@NO, @YES]) {
        XCTAssertTrue(VibePlaybackSeekSettlementIsCurrent(track, track, stopped.boolValue));
        XCTAssertFalse(VibePlaybackSeekSettlementIsCurrent(track, otherRow, stopped.boolValue));
        XCTAssertFalse(VibePlaybackSeekSettlementIsCurrent(track, nil, stopped.boolValue));
        XCTAssertEqual(VibePlaybackSeekSettlementIsCurrent(nil, track, stopped.boolValue), stopped.boolValue);
        XCTAssertEqual(VibePlaybackSeekSettlementIsCurrent(nil, nil, stopped.boolValue), stopped.boolValue);
    }
}

- (void)testPlaybackSettlementAndFallbackCanConsumeMetadataOnlyOnce {
    // Settlement and the fallback timer share this gate. Whichever arrives
    // first consumes it.
    BOOL pending = YES;
    XCTAssertTrue(VibePlaybackConsumePendingMetadataLoad(&pending, 7, 7));
    XCTAssertFalse(pending);
    XCTAssertFalse(VibePlaybackConsumePendingMetadataLoad(&pending, 7, 7));
}

- (void)testOldFallbackCannotConsumeAReplacementOrAppendsPendingMetadata {
    BOOL pending = YES;
    XCTAssertFalse(VibePlaybackConsumePendingMetadataLoad(&pending, 7, 8));
    XCTAssertTrue(pending);
    XCTAssertTrue(VibePlaybackConsumePendingMetadataLoad(&pending, 8, 8));
    XCTAssertFalse(VibePlaybackConsumePendingMetadataLoad(&pending, 7, 8));
}

- (void)testCancelledMetadataRemainsCancelledAtEitherGeneration {
    BOOL pending = NO;
    XCTAssertFalse(VibePlaybackConsumePendingMetadataLoad(&pending, 7, 8));
    XCTAssertFalse(VibePlaybackConsumePendingMetadataLoad(&pending, 8, 8));
    XCTAssertFalse(pending);
}

@end
