//
//  AudioLevelPublisherTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioLevelPublisherInternal.h"

@interface AudioLevelPublisherTests : XCTestCase
@end

@implementation AudioLevelPublisherTests

- (void)testSnapshotIsUnavailableUntilTheCurrentSessionPublishes {
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    float copied[kLevelBandCount] = {-1, -1, -1, -1, -1};
    XCTAssertFalse([publisher copyLevels:copied count:kLevelBandCount
                                 sequence:NULL]);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        XCTAssertEqual(copied[band], -1.0f);
    }

    uint64_t session = [publisher beginSession];
    XCTAssertFalse([publisher copyLevels:copied count:kLevelBandCount
                                 sequence:NULL]);
    float levels[kLevelBandCount] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f};
    XCTAssertTrue(VibeLevelPublisherPublish([publisher publisherState],
                                             session, levels));
    uint64_t sequence = 0;
    XCTAssertTrue([publisher copyLevels:copied count:kLevelBandCount
                                sequence:&sequence]);
    XCTAssertEqual(sequence, 1u);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        XCTAssertEqualWithAccuracy(copied[band], levels[band], 0.0001);
    }
}

- (void)testSequenceAdvancesWhenNumericLevelsDoNotChange {
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    uint64_t session = [publisher beginSession];
    float levels[kLevelBandCount] = {0};
    XCTAssertTrue(VibeLevelPublisherPublish([publisher publisherState],
                                             session, levels));
    float copied[kLevelBandCount];
    uint64_t first = 0;
    XCTAssertTrue([publisher copyLevels:copied count:kLevelBandCount
                                sequence:&first]);
    XCTAssertTrue(VibeLevelPublisherPublish([publisher publisherState],
                                             session, levels));
    uint64_t second = 0;
    XCTAssertTrue([publisher copyLevels:copied count:kLevelBandCount
                                sequence:&second]);
    XCTAssertEqual(second, first + 1);
}

- (void)testNewSessionRejectsTheOldSnapshotAndOldWriter {
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    uint64_t oldSession = [publisher beginSession];
    float oldLevels[kLevelBandCount] = {1, 1, 1, 1, 1};
    XCTAssertTrue(VibeLevelPublisherPublish([publisher publisherState],
                                             oldSession, oldLevels));

    uint64_t newSession = [publisher beginSession];
    float copied[kLevelBandCount] = {0};
    XCTAssertFalse([publisher copyLevels:copied count:kLevelBandCount
                                 sequence:NULL]);
    XCTAssertFalse(VibeLevelPublisherPublish([publisher publisherState],
                                              oldSession, oldLevels));

    float newLevels[kLevelBandCount] = {0.5f, 0.4f, 0.3f, 0.2f, 0.1f};
    XCTAssertTrue(VibeLevelPublisherPublish([publisher publisherState],
                                             newSession, newLevels));
    uint64_t sequence = 0;
    XCTAssertTrue([publisher copyLevels:copied count:kLevelBandCount
                                sequence:&sequence]);
    XCTAssertEqual(sequence, 2u);
    XCTAssertEqualWithAccuracy(copied[0], 0.5f, 0.0001);

    [publisher endSession:newSession];
    XCTAssertFalse([publisher copyLevels:copied count:kLevelBandCount
                                 sequence:NULL]);
}

@end
