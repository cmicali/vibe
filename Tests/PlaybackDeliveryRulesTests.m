//
//  PlaybackDeliveryRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaybackDeliveryRules.h"
#import "Playlist.h"
#import "AppSettings+Mac.h"

@interface PlaybackDeliveryRulesTests : XCTestCase
@end

@implementation PlaybackDeliveryRulesTests

- (void)testTrackEndSettingAndPlaylistBoundaryChooseAdvanceOrPark {
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithURLs:@[[NSURL fileURLWithPath:@"/a.wav"], [NSURL fileURLWithPath:@"/b.wav"]]];
    AppSettings *settings = AppSettings.sharedInstance;
    [settings resetToDefaults];
    @try {
        XCTAssertTrue(VibePlaybackShouldAdvanceAtTrackEnd(playlist.hasNextTrack, settings.pauseAtTrackEnd));
        settings.pauseAtTrackEnd = YES;
        XCTAssertFalse(VibePlaybackShouldAdvanceAtTrackEnd(playlist.hasNextTrack, settings.pauseAtTrackEnd));
        [playlist next];
        for (NSNumber *pause in @[@NO, @YES]) {
            settings.pauseAtTrackEnd = pause.boolValue;
            XCTAssertFalse(VibePlaybackShouldAdvanceAtTrackEnd(playlist.hasNextTrack, settings.pauseAtTrackEnd));
        }
        [playlist clear];
        settings.pauseAtTrackEnd = NO;
        XCTAssertFalse(VibePlaybackShouldAdvanceAtTrackEnd(playlist.hasNextTrack, settings.pauseAtTrackEnd));
    } @finally {
        [settings resetToDefaults];
    }
}

- (void)testDepartedFinishStopsOldStatsWhileReplacementIsOpening {
    NSURL *url = [NSURL fileURLWithPath:@"/same.wav"];
    AudioTrack *old = [AudioTrack withURL:url], *replacement = [AudioTrack withURL:url];
    XCTAssertTrue(VibePlaybackStaleFinishStopsStats(replacement, old));
    XCTAssertTrue(VibePlaybackStaleFinishStopsStats(replacement, nil));
    XCTAssertFalse(VibePlaybackStaleFinishStopsStats(replacement, replacement));
    XCTAssertTrue(VibePlaybackStaleFinishStopsStats(nil, old));
    XCTAssertTrue(VibePlaybackStaleFinishStopsStats(nil, nil));
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
    // Both deliveries call the same production gate. Their order must not
    // matter, and the pending flag is cleared before the caller starts I/O.
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
