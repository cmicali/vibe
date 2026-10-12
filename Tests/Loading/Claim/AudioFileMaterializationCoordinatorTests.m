
#import "AudioFileMaterializationCoordinatorTestCase.h"
#import "CloudTransferRegistry.h"

@interface AudioFileMaterializationCoordinatorTests : AudioFileMaterializationCoordinatorTestCase
@end

@implementation AudioFileMaterializationCoordinatorTests

#pragma mark - Outcome counters

// A counter an oracle reads needs a test that it moves: one stuck at zero
// reads exactly like a clean run.
- (void)testOutcomeCountersMoveWithRealWork {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    VibeAudioFileMaterializationCoordinatorSnapshot before =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(before.requestsReady, 0u);

    XCTestExpectation *ready = [self expectationWithDescription:@"ready"];
    __unused AudioFileMaterializationRequestToken *token = [self requestName:@"counted.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [ready fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    [_controller completeAll];
    [self waitForExpectations:@[ready] timeout:VIBE_TEST_HANG_TIMEOUT];

    VibeAudioFileMaterializationCoordinatorSnapshot after =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(after.requestsReady, 1u, @"requestsReady never moved");
    XCTAssertEqual(after.requestsFailed, 0u);
    XCTAssertEqual(after.requestsAdmissionExhausted, 0u);
    // materializeURL: is stage 1 alone; an open counted here would mean the
    // two stages had been conflated.
    XCTAssertEqual(after.handleOpensStarted, 0u);
    XCTAssertEqual([_coordinator handleOpensInFlight], 0u);
}

- (void)testAdmissionExhaustionIsCounted {
    VibeAudioLoadingConfigurationValues values = VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 1;
    [self makeCoordinatorWithValues:values];
    XCTestExpectation *exhausted = [self expectationWithDescription:@"exhausted"];
    // More than one request is refused.
    exhausted.assertForOverFulfill = NO;
    for (NSUInteger i = 0; i < 4; i++) {
        [self requestName:[NSString stringWithFormat:@"crowd-%lu.wav", (unsigned long)i]
                     role:VibeAudioFileMaterializationRoleMetadataScan
               completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                            NSTimeInterval elapsed) {
            if (result == VibeAudioFileMaterializationResultAdmissionExhausted) {
                [exhausted fulfill];
            }
        }];
    }
    [self waitForExpectations:@[exhausted] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertGreaterThan([_coordinator stateSnapshotForTesting].requestsAdmissionExhausted, 0u,
                         @"requestsAdmissionExhausted never moved");
}

#pragma mark - The initial probe

- (void)testInitialProbeBoundAndPendingCancellationShareOneCoordinatorPolicy {
    NSMutableArray<NSString *> *runningNames = [NSMutableArray array];
    NSMutableArray<NSString *> *pendingNames = [NSMutableArray array];
    for (NSUInteger index = 0; index < 8; index++) {
        NSString *name = [NSString stringWithFormat:@"probe-running-%lu.wav",
                                                   (unsigned long)index];
        [runningNames addObject:name];
        [_probeController setResults:@[@NO] forName:name];
        [_probeController gateCall:1 forName:name];
    }
    for (NSUInteger index = 0; index < 16; index++) {
        NSString *name = [NSString stringWithFormat:@"probe-pending-%lu.wav",
                                                   (unsigned long)index];
        [pendingNames addObject:name];
        [_probeController setResults:@[@NO] forName:name];
    }
    // The pending probes park on the wall clock until the test releases the
    // running ones, so their grace must outlast every wait here.
    VibeAudioLoadingConfigurationValues values = VibeAudioLoadingProductionConfigurationValues();
    values.datalessProbePendingGrace = VIBE_TEST_GATE_TIMEOUT;
    [self makeCoordinatorWithValues:values];

    NSMutableArray<AudioFileMaterializationRequestToken *> *tokens = [NSMutableArray array];
    for (NSString *name in runningNames) {
        [tokens addObject:[self requestName:name
                role:VibeAudioFileMaterializationRoleMetadataScan
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}]];
        XCTAssertTrue([_probeController waitForCallCount:1 forName:name]);
    }
    XCTAssertEqual(_probeController.inFlightCount, 8u);
    XCTAssertEqual([_coordinator datalessProbesInFlight], 8u);

    XCTestExpectation *cancelledSilent =
            [self expectationWithDescription:@"cancelled pending probe silent"];
    cancelledSilent.inverted = YES;
    AudioFileMaterializationRequestToken *cancelled =
            [self requestName:@"cancelled-pending-probe.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [cancelledSilent fulfill];
    }];
    [cancelled cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].claimCount == 8;
    }]);
    XCTAssertEqual([_probeController callCountForName:@"cancelled-pending-probe.wav"], 0u);
    XCTAssertEqual([_coordinator datalessProbesInFlight], 8u,
                   @"cancelling pending work must retire its probe attempt");

    for (NSString *name in pendingNames) {
        [tokens addObject:[self requestName:name
                role:VibeAudioFileMaterializationRoleMetadataScan
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}]];
    }
    XCTestExpectation *overflow = [self expectationWithDescription:@"probe overflow"];
    __unused AudioFileMaterializationRequestToken *refused =
            [self requestName:@"probe-overflow.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultAdmissionExhausted);
        XCTAssertNotNil(error);
        [overflow fulfill];
    }];
    [self waitForExpectations:@[overflow] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([_coordinator stateSnapshotForTesting].claimCount, 24u);
    XCTAssertEqual(_probeController.totalCallCount, 8u);
    XCTAssertEqual([_coordinator datalessProbesInFlight], 24u,
                   @"the gauge covers running and scheduler-pending attempts");
    XCTAssertEqual([_probeController callCountForName:@"probe-overflow.wav"], 0u);

    [_probeController releaseAll];
    // Settled, every claim was probed; idle alone can fall between batches.
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].claimCount == 0;
    }]);
    XCTAssertTrue([_probeController waitForIdle]);
    XCTAssertEqual(_probeController.totalCallCount, 24u);
    XCTAssertEqual(_controller.startedOperations.count, 0u,
                   @"a fresh local answer settles without an operation");
    [self waitForExpectations:@[cancelledSilent] timeout:0.1];
    (void)tokens;
}

- (void)testBlockedInitialProbeDoesNotBlockCallerStateOrAnotherPath {
    [_probeController gateCall:1 forName:@"blocked-probe.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    dispatch_queue_t blockedRequestQueue = dispatch_queue_create(
            "com.vibe.tests.materialization.blocked-request", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t stateReadQueue = dispatch_queue_create(
            "com.vibe.tests.materialization.state-read", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t healthyRequestQueue = dispatch_queue_create(
            "com.vibe.tests.materialization.healthy-request", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *blockedRequestReturned =
            [self expectationWithDescription:@"blocked request returned"];
    __block AudioFileMaterializationRequestToken *blockedToken = nil;
    dispatch_async(blockedRequestQueue, ^{
        blockedToken = [self requestName:@"blocked-probe.wav"
                role:VibeAudioFileMaterializationRolePlayback
                completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                             NSTimeInterval elapsed) {}];
        [blockedRequestReturned fulfill];
    });
    XCTAssertTrue([_probeController waitForCallCount:1 forName:@"blocked-probe.wav"]);

    @try {
        XCTWaiterResult returned = [XCTWaiter waitForExpectations:@[blockedRequestReturned]
                                                       timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertEqual(returned, XCTWaiterResultCompleted,
                       @"the caller inherited the filesystem probe");
        if (returned != XCTWaiterResultCompleted) {
            return;
        }

        XCTestExpectation *stateResponsive =
                [self expectationWithDescription:@"state reads responsive"];
        __block AudioLoadingConfiguration *configuration = nil;
        __block BOOL foregroundActive = NO;
        __block VibeAudioFileMaterializationCoordinatorSnapshot stateSnapshot;
        dispatch_async(stateReadQueue, ^{
            configuration = self->_coordinator.currentConfiguration;
            foregroundActive = [self->_coordinator isForegroundTransferActive];
            stateSnapshot = [self->_coordinator stateSnapshotForTesting];
            [stateResponsive fulfill];
        });

        XCTestExpectation *otherReturned =
                [self expectationWithDescription:@"other request returned"];
        XCTestExpectation *otherReady = [self expectationWithDescription:@"other ready"];
        __block AudioFileMaterializationRequestToken *otherToken = nil;
        dispatch_async(healthyRequestQueue, ^{
            otherToken = [self requestName:@"healthy-probe.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                                 NSTimeInterval elapsed) {
                XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
                [otherReady fulfill];
            }];
            [otherReturned fulfill];
        });

        [self waitForExpectations:@[stateResponsive, otherReturned] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNotNil(configuration);
        XCTAssertTrue(foregroundActive);
        XCTAssertGreaterThanOrEqual(stateSnapshot.claimCount, 1u);
        XCTAssertGreaterThanOrEqual(stateSnapshot.datalessProbesInFlight, 1u);
        XCTAssertTrue([_controller waitForStartedCount:1],
                      @"an unrelated healthy path waited behind the blocked probe");
        VibeTestMaterializationOperation *otherOperation =
                [_controller operationForLastPathComponent:@"healthy-probe.wav"];
        XCTAssertNotNil(otherOperation);
        [otherOperation completeReady:YES];
        [self waitForExpectations:@[otherReady] timeout:VIBE_TEST_HANG_TIMEOUT];
        (void)otherToken;
    }
    @finally {
        [blockedToken cancel];
        [_probeController releaseCall:1 forName:@"blocked-probe.wav"];
    }
}

#pragma mark - Same-path joins and classification

- (void)testSamePathRequestsAtomicallyJoinOneOperation {
    [_probeController gateCall:1 forName:@"same.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *scan = [self expectationWithDescription:@"scan ready"];
    XCTestExpectation *prefetch = [self expectationWithDescription:@"prefetch ready"];
    __unused AudioFileMaterializationRequestToken *first = [self requestName:@"same.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [scan fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:1 forName:@"same.wav"]);
    __unused AudioFileMaterializationRequestToken *second = [self requestName:@"same.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [prefetch fulfill];
    }];
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.claimCount, 1u);
    XCTAssertEqual(snapshot.waiterCount, 2u);
    XCTAssertEqual(_controller.startedOperations.count, 0u);
    XCTAssertEqual([_probeController callCountForName:@"same.wav"], 1u,
                   @"same-path waiters must share the initial probe");

    [_probeController releaseCall:1 forName:@"same.wav"];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *operation =
            [_controller operationForLastPathComponent:@"same.wav"];
    XCTAssertEqual(operation.role, VibeAudioFileMaterializationRolePrefetch);
    XCTAssertEqual([_probeController callCountForName:@"same.wav"], 1u,
                   @"an immediately admitted claim reuses its fresh classification");
    [[_controller operationForLastPathComponent:@"same.wav"] completeReady:YES];
    [self waitForExpectations:@[scan, prefetch] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testImmediateClassificationPublishesOnlyDatalessTransfers {
    [_probeController setResults:@[@NO] forName:@"immediate-local.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

    NSURL *datalessURL = [self URLNamed:@"immediate-dataless.wav"];
    XCTestExpectation *datalessReady =
            [self expectationWithDescription:@"immediate dataless ready"];
    __unused AudioFileMaterializationRequestToken *dataless =
            [self requestName:datalessURL.lastPathComponent
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [datalessReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    [self drainMainQueue];
    XCTAssertTrue([CloudTransferRegistry.sharedRegistry isTransferringURL:datalessURL]);

    [[_controller operationForLastPathComponent:datalessURL.lastPathComponent]
            completeReady:YES];
    [self waitForExpectations:@[datalessReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry isTransferringURL:datalessURL]);

    NSURL *localURL = [self URLNamed:@"immediate-local.wav"];
    XCTestExpectation *localReady =
            [self expectationWithDescription:@"immediate local ready"];
    __unused AudioFileMaterializationRequestToken *local =
            [self requestName:localURL.lastPathComponent
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [localReady fulfill];
    }];
    [self waitForExpectations:@[localReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry isTransferringURL:localURL]);
    XCTAssertEqual(_controller.startedOperations.count, 1u,
                   @"a fresh local answer settles without an operation");
}

#pragma mark - Joining, rebinding and replacing a path claim

- (void)testCurrentTrackMetadataJoinsTheLivePlaybackClaim {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"current.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *metadataReady = [self expectationWithDescription:@"metadata ready"];
    __unused AudioFileMaterializationRequestToken *metadata = [self requestName:@"current.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [metadataReady fulfill];
    }];
    VibeAudioFileMaterializationCoordinatorSnapshot joined =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(joined.claimCount, 1u);
    XCTAssertEqual(joined.waiterCount, 2u);
    XCTAssertEqual(_controller.startedOperations.count, 1u,
                   @"metadata for the current track must join playback's transfer");

    [_controller.startedOperations.firstObject completeReady:YES];
    [self waitForExpectations:@[playbackReady, metadataReady] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testCancelledRunRebindsOnePathClaimAndRestartsAtThePromotedRole {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *oldSilent = [self expectationWithDescription:@"cancelled waiter silent"];
    oldSilent.inverted = YES;
    AudioFileMaterializationRequestToken *old = [self requestName:@"promoted.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *first = _controller.startedOperations.firstObject;
    XCTAssertEqual(first.role, VibeAudioFileMaterializationRoleMetadataScan);
    [first deferCancellationCompletion];
    [old cancel];

    XCTestExpectation *playbackReady = [self expectationWithDescription:@"rebound playback ready"];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"promoted.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    VibeAudioFileMaterializationCoordinatorSnapshot rebound =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(rebound.claimCount, 1u);
    XCTAssertEqual(rebound.waiterCount, 1u);
    XCTAssertEqual(_controller.startedOperations.count, 1u);
    XCTAssertEqual(first.cancellationCount, 1u);

    [first completeReady:NO];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *second = _controller.startedOperations.lastObject;
    XCTAssertEqual(second.role, VibeAudioFileMaterializationRolePlayback);
    XCTAssertEqual([_probeController callCountForName:@"promoted.wav"], 2u,
                   @"a dataless readmission refreshes before restarting");
    [second completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
    VibeAudioFileMaterializationCoordinatorSnapshot settled =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(settled.claimCount, 0u);
    XCTAssertEqual(settled.waiterCount, 0u);
}

- (void)testReadyAfterCancellationRebindsWithoutRefreshingTheNowLocalPath {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *oldSilent = [self expectationWithDescription:@"cancelled waiter silent"];
    oldSilent.inverted = YES;
    AudioFileMaterializationRequestToken *old = [self requestName:@"ready-rebind.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *first = _controller.startedOperations.firstObject;
    [first deferCancellationCompletion];
    [old cancel];

    XCTestExpectation *replacementReady =
            [self expectationWithDescription:@"replacement ready"];
    __unused AudioFileMaterializationRequestToken *replacement =
            [self requestName:@"ready-rebind.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [replacementReady fulfill];
    }];

    [first completeReady:YES];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual([_probeController callCountForName:@"ready-rebind.wav"], 1u,
                   @"a ready cancelled run makes its readmission local");
    [_controller.startedOperations.lastObject completeReady:YES];
    [self waitForExpectations:@[replacementReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
}

- (void)testReplacementDuringRefreshReusesItsFreshDatalessClassification {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @YES] forName:@"refresh-replacement.wav"];
    [_probeController gateCall:2 forName:@"refresh-replacement.wav"];
    [_probeController gateCall:3 forName:@"refresh-replacement.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"refresh-replacement-blocker.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *oldSilent = [self expectationWithDescription:@"cancelled waiter silent"];
    oldSilent.inverted = YES;
    AudioFileMaterializationRequestToken *old =
            [self requestName:@"refresh-replacement.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    [[_controller operationForLastPathComponent:@"refresh-replacement-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2
                                              forName:@"refresh-replacement.wav"]);
    VibeTestMaterializationOperation *cancelledRefreshOperation =
            [_controller operationForLastPathComponent:@"refresh-replacement.wav"];

    [old cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return cancelledRefreshOperation.cancellationCount == 1
                && [self->_coordinator stateSnapshotForTesting].waiterCount == 0;
    }]);

    XCTestExpectation *replacementReady =
            [self expectationWithDescription:@"replacement playback ready"];
    __unused AudioFileMaterializationRequestToken *replacement =
            [self requestName:@"refresh-replacement.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [replacementReady fulfill];
    }];
    VibeAudioFileMaterializationCoordinatorSnapshot rebound =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(rebound.claimCount, 1u);
    XCTAssertEqual(rebound.waiterCount, 1u);
    XCTAssertTrue(rebound.foregroundTransferActive);

    [_probeController releaseCall:2 forName:@"refresh-replacement.wav"];
    BOOL replacementStarted = [_controller waitForStartedCount:2];
    XCTAssertTrue(replacementStarted,
                  @"immediate readmission must not wait on a second refresh");
    XCTAssertEqual([_probeController callCountForName:@"refresh-replacement.wav"], 2u,
                   @"the accepted refresh classification is fresh for readmission");
    [_probeController releaseCall:3 forName:@"refresh-replacement.wav"];
    if (!replacementStarted) {
        return;
    }

    VibeTestMaterializationOperation *replacementOperation =
            [_controller operationForLastPathComponent:@"refresh-replacement.wav"];
    XCTAssertNotEqual(replacementOperation, cancelledRefreshOperation);
    XCTAssertEqual(replacementOperation.role, VibeAudioFileMaterializationRolePlayback);
    XCTAssertTrue([_coordinator isForegroundTransferActive]);
    [self drainMainQueue];
    XCTAssertTrue([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"refresh-replacement.wav"]]);

    [replacementOperation completeReady:YES];
    [self waitForExpectations:@[replacementReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"refresh-replacement.wav"]]);
    XCTAssertFalse([_coordinator isForegroundTransferActive]);
}

- (void)testAStaleInitialProbeCannotClassifyAReplacementClaimForTheSamePath {
    [_probeController setResults:@[@YES, @NO] forName:@"stale-probe.wav"];
    [_probeController gateCall:1 forName:@"stale-probe.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

    XCTestExpectation *oldSilent = [self expectationWithDescription:@"cancelled waiter silent"];
    oldSilent.inverted = YES;
    AudioFileMaterializationRequestToken *old = [self requestName:@"stale-probe.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:1 forName:@"stale-probe.wav"]);
    [old cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].claimCount == 0;
    }]);
    XCTAssertEqual([_coordinator datalessProbesInFlight], 1u,
                   @"a detached claim must not hide its occupied probe worker");

    XCTestExpectation *replacementReady =
            [self expectationWithDescription:@"replacement ready"];
    __unused AudioFileMaterializationRequestToken *replacement =
            [self requestName:@"stale-probe.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [replacementReady fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:2 forName:@"stale-probe.wav"]);
    [self waitForExpectations:@[replacementReady] timeout:VIBE_TEST_HANG_TIMEOUT];

    [_probeController releaseCall:1 forName:@"stale-probe.wav"];
    XCTAssertTrue([_probeController waitForIdle]);
    XCTAssertEqual(_controller.startedOperations.count, 0u,
                   @"the old dataless answer must not start a run for the replacement");
    [self waitForExpectations:@[oldSilent] timeout:0.1];
}

#pragma mark - Cancellation and restarts

// The provider's dying fetch of a transfer a rising edge just cancelled can
// bleed into a fresh coordinated read of the same file as a cancellation
// nobody ordered; that is not a verdict on the file.
- (void)testAnUnorderedCancellationRestartsTheRunInsteadOfFailingIt {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *ready = [self expectationWithDescription:@"ready after restart"];
    __unused AudioFileMaterializationRequestToken *token = [self requestName:@"inherited.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        XCTAssertNil(error);
        [ready fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *first = _controller.startedOperations.firstObject;
    XCTAssertEqual(first.cancellationCount, 0u);
    // A not-ready run reports NSUserCancelledError, the materializer's one
    // spelling, with no cancel issued.
    [first completeReady:NO];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual([_probeController callCountForName:@"inherited.wav"], 2u);
    [_controller.startedOperations.lastObject completeReady:YES];
    [self waitForExpectations:@[ready] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testInheritedCancellationRestartsAreBounded {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *failed = [self expectationWithDescription:@"failed after the bound"];
    __unused AudioFileMaterializationRequestToken *token = [self requestName:@"stuck.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultFailed);
        XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
        XCTAssertEqual(error.code, NSUserCancelledError);
        [failed fulfill];
    }];
    for (NSUInteger attempt = 1; attempt <= 3; attempt++) {
        XCTAssertTrue([_controller waitForStartedCount:attempt]);
        [_controller.startedOperations.lastObject completeReady:NO];
    }
    [self waitForExpectations:@[failed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 3u);
    XCTAssertEqual([_probeController callCountForName:@"stuck.wav"], 3u);
}

- (void)testAnOrdinaryFailureDoesNotRestart {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    NSError *providerError = [NSError errorWithDomain:@"com.test.provider"
                                                 code:7 userInfo:nil];
    XCTestExpectation *failed = [self expectationWithDescription:@"failed once"];
    __unused AudioFileMaterializationRequestToken *token = [self requestName:@"broken.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result,
                         NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultFailed);
        XCTAssertEqualObjects(error.domain, @"com.test.provider");
        [failed fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    [_controller.startedOperations.firstObject completeWithError:providerError];
    [self waitForExpectations:@[failed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].requestsFailed, 1u,
                   @"requestsFailed never moved");
}

- (void)testCancellingOneWaiterLeavesThePathOwnerForTheOther {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    __block NSUInteger cancelledDeliveries = 0;
    AudioFileMaterializationRequestToken *cancelled = [self requestName:@"joined.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        cancelledDeliveries++;
    }];
    XCTestExpectation *survivor = [self expectationWithDescription:@"survivor"];
    __unused AudioFileMaterializationRequestToken *live = [self requestName:@"joined.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [survivor fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    [cancelled cancel];
    [[_controller operationForLastPathComponent:@"joined.wav"] completeReady:YES];
    [self waitForExpectations:@[survivor] timeout:VIBE_TEST_HANG_TIMEOUT];
    dispatch_sync(_completionQueue, ^{});
    XCTAssertEqual(cancelledDeliveries, 0u);
    XCTAssertEqual(_controller.totalCancellationCount, 0u);
}

#pragma mark - Concurrency changes and expiry

- (void)testLiveConcurrencyRaiseAdmitsAndLoweringOnlyDrains {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 6;
    [_probeController gateCall:1 forName:@"b.wav"];
    [self makeCoordinatorWithValues:values];
    NSMutableDictionary<NSString *, XCTestExpectation *> *done = [NSMutableDictionary dictionary];
    NSMutableArray<AudioFileMaterializationRequestToken *> *tokens = [NSMutableArray array];
    for (NSString *name in @[@"a.wav", @"b.wav", @"c.wav"]) {
        XCTestExpectation *expectation = [self expectationWithDescription:name];
        done[name] = expectation;
        [tokens addObject:[self requestName:name role:VibeAudioFileMaterializationRolePrefetch
                completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
            [expectation fulfill];
        }]];
        if ([name isEqualToString:@"a.wav"]) {
            XCTAssertTrue([_controller waitForStartedCount:1]);
        }
        if ([name isEqualToString:@"b.wav"]) {
            XCTAssertTrue([_probeController waitForCallCount:1 forName:name]);
        }
    }
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }], @"the later healthy path never reached Pending");
    [_probeController releaseCall:1 forName:@"b.wav"];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 2;
    }]);
    // A dataless claim queued behind lane capacity has nothing on the wire, so
    // its row shows no loading bar.
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"b.wav"]]);

    values.maximumBackgroundMaterializations = 2;
    [_coordinator applyConfiguration:[self configurationWithValues:values]];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *second = _controller.startedOperations[1];
    XCTAssertEqualObjects(second.url.lastPathComponent, @"b.wav",
            @"pending rank must use registration ordinal, not probe completion order");
    XCTAssertEqual([_probeController callCountForName:@"b.wav"], 2u,
            @"a delayed dataless start refreshes before its operation");
    [self drainMainQueue];
    XCTAssertTrue([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"b.wav"]]);
    values.maximumBackgroundMaterializations = 1;
    [_coordinator applyConfiguration:[self configurationWithValues:values]];

    XCTestExpectation *dDone = [self expectationWithDescription:@"d.wav"];
    done[@"d.wav"] = dDone;
    [tokens addObject:[self requestName:@"d.wav" role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        [dDone fulfill];
    }]];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 2;
    }]);

    XCTAssertEqual(_coordinator.currentConfiguration.maximumBackgroundMaterializations, 1u);
    [[_controller operationForLastPathComponent:@"a.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"a.wav"]] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 2u,
                   @"lowering must wait for every excess running operation to drain");
    [[_controller operationForLastPathComponent:@"b.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"b.wav"]] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"b.wav"]]);
    XCTAssertTrue([_controller waitForStartedCount:3]);
    XCTAssertEqual(_controller.totalCancellationCount, 0u);
    [[_controller operationForLastPathComponent:@"c.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"c.wav"]] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_controller waitForStartedCount:4]);
    [[_controller operationForLastPathComponent:@"d.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"d.wav"]] timeout:VIBE_TEST_HANG_TIMEOUT];
    (void)tokens;
}

- (void)testExpiredClaimsFailBeforeAConcurrencyRaiseCanStartThem {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 3;
    values.backgroundAdmissionGrace = 10;
    [self makeCoordinatorWithValues:values];
    __unused AudioFileMaterializationRequestToken *blocker = [self requestName:@"running.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {}];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    XCTestExpectation *expired = [self expectationWithDescription:@"expired"];
    __unused AudioFileMaterializationRequestToken *pending = [self requestName:@"expired.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultAdmissionExhausted);
        [expired fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);

    _now = 111;
    values.maximumBackgroundMaterializations = 2;
    [_coordinator applyConfiguration:[self configurationWithValues:values]];
    [self waitForExpectations:@[expired] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u);
}

- (void)testExpiredClaimFailsWhenACompletedOperationFreesItsLane {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 3;
    values.backgroundAdmissionGrace = 10;
    [self makeCoordinatorWithValues:values];
    XCTestExpectation *blockerDone = [self expectationWithDescription:@"blocker done"];
    __unused AudioFileMaterializationRequestToken *blocker = [self requestName:@"running.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [blockerDone fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    XCTestExpectation *expired = [self expectationWithDescription:@"expired"];
    __unused AudioFileMaterializationRequestToken *pending = [self requestName:@"expired.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultAdmissionExhausted);
        [expired fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);

    _now = 111;
    [[_controller operationForLastPathComponent:@"running.wav"] completeReady:YES];
    [self waitForExpectations:@[blockerDone, expired] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u);
}

- (void)testFreshSamePathRequestCannotReviveAnExpiredClaim {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 3;
    values.backgroundAdmissionGrace = 10;
    [self makeCoordinatorWithValues:values];
    // A metadata blocker, not a prefetch: a foreground claim would make the
    // dataless metadata request below yield at entry rather than park, and
    // parking is the state under test.
    __unused AudioFileMaterializationRequestToken *blocker = [self requestName:@"running.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {}];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    XCTestExpectation *expired = [self expectationWithDescription:@"expired waiter"];
    __unused AudioFileMaterializationRequestToken *old = [self requestName:@"same.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultAdmissionExhausted);
        [expired fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);

    _now = 111;
    // Metadata again, not a foreground role: a prefetch here would exercise
    // the rising-edge preemption and cancel the blocker, which is its own
    // test — this one is only about the expired claim not being revived.
    XCTestExpectation *freshReady = [self expectationWithDescription:@"fresh waiter ready"];
    __unused AudioFileMaterializationRequestToken *fresh = [self requestName:@"same.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [freshReady fulfill];
    }];
    [self waitForExpectations:@[expired] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u);

    [[_controller operationForLastPathComponent:@"running.wav"] completeReady:YES];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *same =
            [_controller operationForLastPathComponent:@"same.wav"];
    XCTAssertEqual(same.role, VibeAudioFileMaterializationRoleMetadataScan);
    [same completeReady:YES];
    [self waitForExpectations:@[freshReady] timeout:VIBE_TEST_HANG_TIMEOUT];
}

@end
