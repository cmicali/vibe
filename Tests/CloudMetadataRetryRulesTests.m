//
//  What the metadata cloud lane does with a failed materialization: a
//  foreground-open hold requeues free and at rank, every other failure gets a
//  bounded budget of retries from the bottom of the lane.
//

#import <XCTest/XCTest.h>

#import "CloudMetadataRetryRules.h"

@interface CloudMetadataRetryRulesTests : XCTestCase
@end

@implementation CloudMetadataRetryRulesTests

- (NSError *)cancelled {
    // Exactly what CloudFileMaterializer's VibeMaterializationCancelledError is.
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:NSUserCancelledError
                           userInfo:nil];
}

- (VibeCloudMetadataRetry)verdictFor:(NSError *)error
                            prepared:(NSUInteger)prepared
                             current:(NSUInteger)current
                            attempts:(NSUInteger)attempts {
    return VibeCloudMetadataRetryForMaterializationFailure(
            error, prepared, current, attempts, kVibeCloudMetadataMaxAttempts);
}

#pragma mark - The hold

- (void)testHoldCancellationRequeuesAtItsCurrentRank {
    XCTAssertEqual([self verdictFor:self.cancelled prepared:4 current:5 attempts:0],
            VibeCloudMetadataRetryAtCurrentRank);
}

// The whole point of not charging the hold: a listener skipping through a
// cloud folder holds the lane repeatedly, and a budget spent on that would
// strand every row it interrupted.
- (void)testRepeatedHoldCancellationsNeverExhaustTheBudget {
    for (NSUInteger attempts = 0; attempts < kVibeCloudMetadataMaxAttempts + 5; attempts++) {
        XCTAssertEqual([self verdictFor:self.cancelled prepared:attempts current:attempts + 1
                               attempts:attempts],
                VibeCloudMetadataRetryAtCurrentRank);
    }
}

- (void)testCancellationWithoutAHoldIsAnOrdinaryFailure {
    // The generation did not move, so nothing the app did explains this.
    XCTAssertEqual([self verdictFor:self.cancelled prepared:4 current:4 attempts:0],
            VibeCloudMetadataRetryDeferred);
}

- (void)testACancellationSpelledAnyOtherWayIsNotAHold {
    // Guards the TRAP in the header: only NSCocoaErrorDomain/NSUserCancelledError
    // is the materializer's cancellation.
    NSError *urlCancelled = [NSError errorWithDomain:NSURLErrorDomain
                                                code:NSURLErrorCancelled
                                            userInfo:nil];
    XCTAssertFalse(VibeCloudMetadataFailureIsHoldCancellation(urlCancelled, 4, 5));
    XCTAssertEqual([self verdictFor:urlCancelled prepared:4 current:5 attempts:0],
            VibeCloudMetadataRetryDeferred);
}

#pragma mark - The bounded budget

- (void)testAProviderFailureDuringAHoldStillSpendsAnAttempt {
    NSError *providerFailure = [NSError errorWithDomain:@"com.example.file-provider"
                                                   code:401
                                               userInfo:nil];
    XCTAssertEqual([self verdictFor:providerFailure prepared:4 current:5 attempts:0],
            VibeCloudMetadataRetryDeferred);
}

- (void)testATerminalFileErrorRetriesUntilTheBudgetRunsOut {
    NSError *missing = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadNoSuchFileError
                                        userInfo:nil];
    // Three total attempts: the first two failures leave one more to make.
    XCTAssertEqual([self verdictFor:missing prepared:4 current:4 attempts:0],
            VibeCloudMetadataRetryDeferred);
    XCTAssertEqual([self verdictFor:missing prepared:4 current:4 attempts:1],
            VibeCloudMetadataRetryDeferred);
    XCTAssertEqual([self verdictFor:missing prepared:4 current:4 attempts:2],
            VibeCloudMetadataRetryNone);
}

- (void)testTheBudgetStaysSpentOnceItIsGone {
    NSError *missing = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadNoSuchFileError
                                        userInfo:nil];
    XCTAssertEqual([self verdictFor:missing prepared:4 current:4 attempts:9],
            VibeCloudMetadataRetryNone);
}

// A budget of one means try once and stop, never "try once more".
- (void)testASingleAttemptBudgetNeverRetries {
    NSError *missing = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadNoSuchFileError
                                        userInfo:nil];
    XCTAssertEqual(VibeCloudMetadataRetryForMaterializationFailure(missing, 4, 4, 0, 1),
            VibeCloudMetadataRetryNone);
}

// A hold is not a failure, so it must not be charged even at a budget of one.
- (void)testASingleAttemptBudgetStillYieldsToTheHold {
    XCTAssertEqual(VibeCloudMetadataRetryForMaterializationFailure(self.cancelled, 4, 5, 0, 1),
            VibeCloudMetadataRetryAtCurrentRank);
}

- (void)testANilErrorIsAnOrdinaryFailureRatherThanAHold {
    XCTAssertFalse(VibeCloudMetadataFailureIsHoldCancellation(nil, 4, 5));
    XCTAssertEqual([self verdictFor:nil prepared:4 current:5 attempts:0],
            VibeCloudMetadataRetryDeferred);
}

@end
