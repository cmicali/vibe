//
// Prefetch retirement across play races and abandonment.
//

#import <XCTest/XCTest.h>

#import "AudioPrefetchRules.h"

@interface AudioPrefetchRulesTests : XCTestCase
@end

@implementation AudioPrefetchRulesTests

- (void)testPlaySubmissionCancelsOnlyAnUnrelatedOldPrefetch {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySubmission, @"/next.flac", @"/picked.flac"));
    XCTAssertFalse(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySubmission, @"/picked.flac", @"/picked.flac"));
}

- (void)testSettledPlayRetiresItsSamePathPrefetchRacer {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySettlement, @"/picked.flac", @"/picked.flac"));
    XCTAssertFalse(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySettlement, @"/later.flac", @"/picked.flac"));
}

- (void)testStopAndFailureAlwaysRetireTheWholePark {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtAbandonment, @"/next.flac", nil));
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtAbandonment, nil, nil));
}

@end
