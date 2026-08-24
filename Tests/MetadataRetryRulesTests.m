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

// The priority record's yield triage, judged at delivery and re-judged on
// every gated tick. A local file retries whether or not the rule holds: its
// parse starts no transfer, and waiting it out was measured costing the
// now-playing tags the length of the successor's whole prefetch. A dataless
// record waits while the hold is up — re-picking would repeat the bounded
// probe and yield when its answer lands — and demotes only once the foreground
// settles with the file still dataless: the open failed, and re-downloading a
// dead pick behind its error UI is the sweep's call to make, at its rank.
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

// Priority failures spend the SAME shared budget the scan does — there is no
// separate priority predicate. This pins the regression 925209b fixed: the
// budget rule was correct and tested while the priority lane fed it no state,
// so the tested decision was unreachable. One rule, one ledger, both slots.
- (void)testPriorityFailuresShareTheScanBudgetRule {
    XCTAssertEqual(VibeMetadataMaterializationRetryForResult(
            VibeAudioFileMaterializationResultFailed, 2, 3),
            VibeMetadataMaterializationRetryNone);
}

@end
