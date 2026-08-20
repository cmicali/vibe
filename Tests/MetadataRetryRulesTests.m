//
//  MetadataRetryRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "MetadataRetryRules.h"

@interface MetadataRetryRulesTests : XCTestCase
@end

@implementation MetadataRetryRulesTests

- (void)testYieldRequeuesAtCurrentRankWithoutSpendingAttemptBudget {
    for (NSUInteger failures = 0; failures < 8; failures++) {
        XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
                VibeAudioFileMaterializationResultYielded, failures, 1),
                VibeMetadataMaterializationRetryAtCurrentRank);
    }
}

- (void)testFileFailureUsesTheBoundedDeferredBudget {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 0, 3),
            VibeMetadataMaterializationRetryDeferred);
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 1, 3),
            VibeMetadataMaterializationRetryDeferred);
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 2, 3),
            VibeMetadataMaterializationRetryNone);
}

- (void)testAdmissionExhaustionCannotImmediatelySpendItsNextAttempt {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultAdmissionExhausted, 0, 3),
            VibeMetadataMaterializationRetryDeferredAfterDelay);
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultAdmissionExhausted, 1, 3),
            VibeMetadataMaterializationRetryDeferredAfterDelay);
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultAdmissionExhausted, 2, 3),
            VibeMetadataMaterializationRetryNone);
}

- (void)testSingleAttemptBudgetDoesNotRetryFailure {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 0, 1),
            VibeMetadataMaterializationRetryNone);
}

- (void)testZeroAttemptBudgetDoesNotUnderflow {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultAdmissionExhausted, 0, 0),
            VibeMetadataMaterializationRetryNone);
}

- (void)testReadyDoesNotRequeue {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultReady, 0, 3),
            VibeMetadataMaterializationRetryNone);
}

- (void)testNoRetriesStillAllowsTheInitialAttempt {
    XCTAssertEqual(VibeMetadataMaximumAttemptsForRetryCount(0), 1u);
}

- (void)testProductionRetryCountAllowsThreeTotalAttempts {
    XCTAssertEqual(VibeMetadataMaximumAttemptsForRetryCount(2), 3u);
}

- (void)testHostileMaximumRetryCountSaturates {
    XCTAssertEqual(VibeMetadataMaximumAttemptsForRetryCount(NSUIntegerMax),
                   NSUIntegerMax);
}

- (void)testAdmissionRetryDelayIsPositiveAndBounded {
    XCTAssertEqualWithAccuracy(VibeMetadataAdmissionRetryDelay(0), 0.25, 0.001);
    XCTAssertEqualWithAccuracy(VibeMetadataAdmissionRetryDelay(1), 0.5, 0.001);
    XCTAssertEqualWithAccuracy(VibeMetadataAdmissionRetryDelay(7), 2.0, 0.001);
    XCTAssertEqualWithAccuracy(VibeMetadataAdmissionRetryDelay(NSUIntegerMax), 2.0, 0.001);
}

// The two interleavings that dropped the storm winner's single request: a
// Yielded delivery marshalling to main AFTER the hold released retries rather
// than clearing, and a park (delivery landed while held) retries at release
// with no later-edge precondition.
- (void)testYieldDeliveredAfterHoldReleaseRetries {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(NO, NO),
            VibeMetadataPriorityYieldActionRetry);
}

- (void)testYieldDeliveredWhileHeldParksAndReleaseRetries {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, NO),
            VibeMetadataPriorityYieldActionPark);
    XCTAssertEqual(VibeMetadataPriorityActionForHoldRelease(NO),
            VibeMetadataPriorityYieldActionRetry);
}

- (void)testCancelledLoaderClearsYieldsAndParks {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(NO, YES),
            VibeMetadataPriorityYieldActionClear);
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, YES),
            VibeMetadataPriorityYieldActionClear);
    XCTAssertEqual(VibeMetadataPriorityActionForHoldRelease(YES),
            VibeMetadataPriorityYieldActionClear);
}

- (void)testPriorityFailureRetriesWithinTheSharedBudget {
    // Three attempts: two prior failures still retry, the third does not.
    XCTAssertTrue(VibeMetadataPriorityRetryAfterFailure(0, 3, NO));
    XCTAssertTrue(VibeMetadataPriorityRetryAfterFailure(1, 3, NO));
    XCTAssertFalse(VibeMetadataPriorityRetryAfterFailure(2, 3, NO));
}

- (void)testPriorityFailureNeverRetriesCancelledOrUnbudgeted {
    XCTAssertFalse(VibeMetadataPriorityRetryAfterFailure(0, 3, YES));
    XCTAssertFalse(VibeMetadataPriorityRetryAfterFailure(0, 0, NO));
}

@end
