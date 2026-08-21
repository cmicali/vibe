//
//  PlaybackDeliveryRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaybackDeliveryRules.h"

@interface PlaybackDeliveryRulesTests : XCTestCase
@end

@implementation PlaybackDeliveryRulesTests

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
