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

- (void)testADatalessYieldWhileHeldWaitsForTheReleaseEdge {
    XCTAssertEqual(VibeMetadataPriorityAfterYield(YES, NO),
            VibeMetadataPriorityYieldWait);
}

- (void)testAFileTheOpenMadeLocalRetriesEvenWhileHeld {
    XCTAssertEqual(VibeMetadataPriorityAfterYield(YES, YES),
            VibeMetadataPriorityYieldRetry);
    XCTAssertEqual(VibeMetadataPriorityAfterYield(NO, YES),
            VibeMetadataPriorityYieldRetry);
}

- (void)testAStillDatalessFileDemotesToTheSweep {
    XCTAssertEqual(VibeMetadataPriorityAfterYield(NO, NO),
            VibeMetadataPriorityYieldDemote);
}

// The priority lane has no predicate of its own: its failures spend the scan's
// budget through this one rule.
- (void)testPriorityFailuresShareTheScanBudgetRule {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 2, 3),
            VibeMetadataMaterializationRetryNone);
}

@end
