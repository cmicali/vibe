//
//  MetadataMaterializationRetryRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "MetadataMaterializationRetryRules.h"

@interface MetadataMaterializationRetryRulesTests : XCTestCase
@end

@implementation MetadataMaterializationRetryRulesTests

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

- (void)testDidStartRecordedBeforeDelayedYieldDeliveryRequestsRetry {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, NO, NO),
            VibeMetadataPriorityYieldActionRetry);
    XCTAssertEqual(VibeMetadataPriorityActionForYield(NO, NO, NO),
            VibeMetadataPriorityYieldActionClear);
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, NO, YES),
            VibeMetadataPriorityYieldActionClear);
}

- (void)testDidStartRecordedBeforeHoldReleaseParksUntilRelease {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, YES, NO),
            VibeMetadataPriorityYieldActionPark);
}

- (void)testYieldThenDidStartThenReleaseRetries {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(NO, YES, NO),
            VibeMetadataPriorityYieldActionPark);
    XCTAssertEqual(VibeMetadataPriorityActionForHoldRelease(YES, NO),
            VibeMetadataPriorityYieldActionRetry);
}

- (void)testDidStartThenYieldThenReleaseRetries {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(YES, YES, NO),
            VibeMetadataPriorityYieldActionPark);
    XCTAssertEqual(VibeMetadataPriorityActionForHoldRelease(YES, NO),
            VibeMetadataPriorityYieldActionRetry);
}

- (void)testYieldThenErrorReleaseWithoutDidStartClears {
    XCTAssertEqual(VibeMetadataPriorityActionForYield(NO, YES, NO),
            VibeMetadataPriorityYieldActionPark);
    XCTAssertEqual(VibeMetadataPriorityActionForHoldRelease(NO, NO),
            VibeMetadataPriorityYieldActionClear);
}

@end
