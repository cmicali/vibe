//
//  PlaybackDeliveryRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaybackDeliveryRules.h"
#import "VibeTestTrack.h"

@interface PlaybackDeliveryRulesTests : XCTestCase
@end

@implementation PlaybackDeliveryRulesTests

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
    VibeTestTrack *track = [VibeTestTrack withURL:url], *otherRow = [VibeTestTrack withURL:url];
    for (NSNumber *stopped in @[@NO, @YES]) {
        XCTAssertTrue(VibePlaybackSeekSettlementIsCurrent(track, track, stopped.boolValue));
        XCTAssertFalse(VibePlaybackSeekSettlementIsCurrent(track, otherRow, stopped.boolValue));
        XCTAssertFalse(VibePlaybackSeekSettlementIsCurrent(track, nil, stopped.boolValue));
        XCTAssertEqual(VibePlaybackSeekSettlementIsCurrent(nil, track, stopped.boolValue), stopped.boolValue);
        XCTAssertEqual(VibePlaybackSeekSettlementIsCurrent(nil, nil, stopped.boolValue), stopped.boolValue);
    }
}

- (void)testPlaybackSettlementAndFallbackCanConsumeMetadataOnlyOnce {
    // Settlement and the fallback timer share this gate; whichever arrives
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

- (void)testMatchingSubmissionOwnsDelivery {
    XCTAssertTrue(VibePlaybackDeliveryIsCurrent(7, 7));
}

- (void)testNewerSubmissionDropsSameTrackDelivery {
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(7, 8));
}

- (void)testGaplessPromotionRetainsOriginalPlayOwner {
    uint64_t explicitPlayOwner = 7;
    XCTAssertTrue(VibePlaybackDeliveryIsCurrent(explicitPlayOwner, 7));
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(explicitPlayOwner, 8));
}

- (void)testNaturalEndQueuedBeforeSameRowReplayIsDropped {
    uint64_t finishedPlayOwner = 10;
    uint64_t sameRowReplay = 11;
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(finishedPlayOwner, sameRowReplay));
}

- (void)testZeroIdentifierNeverOwnsDelivery {
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(0, 0));
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(0, 1));
}

- (void)testResumeErrorQueuedBeforeSameRowReplayIsDropped {
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(14, 15));
}

- (void)testSeekRestartErrorQueuedBeforeSameRowReplayIsDropped {
    XCTAssertFalse(VibePlaybackDeliveryIsCurrent(21, 22));
}

- (void)testMediaResetCompletionCanUseTheInitialSubmissionState {
    XCTAssertTrue(VibePlaybackSubmissionStateIsUnchanged(0, 0));
}

- (void)testMediaResetCompletionCannotReparkOverANewerPlay {
    XCTAssertFalse(VibePlaybackSubmissionStateIsUnchanged(31, 32));
}

@end
