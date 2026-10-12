//
//  AudioFileMaterializationCoordinatorForegroundTests.m
//  VibeTests
//
//  Stage 1's foreground hold: its edges during a probe or a refresh, and the
//  local files it passes through.
//

#import "AudioFileMaterializationCoordinatorTestCase.h"
#import "CloudTransferRegistry.h"

@interface AudioFileMaterializationCoordinatorForegroundTests : AudioFileMaterializationCoordinatorTestCase
@end

@implementation AudioFileMaterializationCoordinatorForegroundTests

#pragma mark - Foreground edges during a probe or refresh

- (void)testForegroundDepartureDuringInitialProbePassesLocalPassengersAndYieldsDatalessOnes {
    [_probeController setResults:@[@NO] forName:@"depart-initial-local.wav"];
    [_probeController gateCall:1 forName:@"depart-initial-local.wav"];
    [_probeController gateCall:1 forName:@"depart-initial-cloud.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

    AudioFileMaterializationRequestToken *localForeground =
            [self requestName:@"depart-initial-local.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {}];
    XCTAssertTrue([_probeController waitForCallCount:1
                                              forName:@"depart-initial-local.wav"]);
    XCTestExpectation *localReady = [self expectationWithDescription:@"local passenger ready"];
    __unused AudioFileMaterializationRequestToken *localMetadata =
            [self requestName:@"depart-initial-local.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [localReady fulfill];
    }];
    [localForeground cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return ![self->_coordinator isForegroundTransferActive];
    }]);
    [_probeController releaseCall:1 forName:@"depart-initial-local.wav"];
    [self waitForExpectations:@[localReady] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioFileMaterializationRequestToken *cloudForeground =
            [self requestName:@"depart-initial-cloud.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {}];
    XCTAssertTrue([_probeController waitForCallCount:1
                                              forName:@"depart-initial-cloud.wav"]);
    XCTestExpectation *cloudYielded =
            [self expectationWithDescription:@"dataless passenger yielded"];
    __unused AudioFileMaterializationRequestToken *cloudMetadata =
            [self requestName:@"depart-initial-cloud.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [cloudYielded fulfill];
    }];
    [cloudForeground cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return ![self->_coordinator isForegroundTransferActive];
    }]);
    [_probeController releaseCall:1 forName:@"depart-initial-cloud.wav"];
    [self waitForExpectations:@[cloudYielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 0u);
    XCTAssertEqual([_probeController callCountForName:@"depart-initial-local.wav"], 1u);
    XCTAssertEqual([_probeController callCountForName:@"depart-initial-cloud.wav"], 1u);
}

- (void)testForegroundDepartureDuringRefreshPassesALocalPassenger {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @NO] forName:@"depart-refresh-local.wav"];
    [_probeController gateCall:2 forName:@"depart-refresh-local.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"depart-refresh-local-blocker.wav"
                    role:VibeAudioFileMaterializationRolePrefetch
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    AudioFileMaterializationRequestToken *foreground =
            [self requestName:@"depart-refresh-local.wav"
                    role:VibeAudioFileMaterializationRolePrefetch
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {}];
    XCTestExpectation *metadataReady =
            [self expectationWithDescription:@"local metadata passenger ready"];
    __unused AudioFileMaterializationRequestToken *metadata =
            [self requestName:@"depart-refresh-local.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [metadataReady fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    [[_controller operationForLastPathComponent:@"depart-refresh-local-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2
                                              forName:@"depart-refresh-local.wav"]);

    [foreground cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return ![self->_coordinator isForegroundTransferActive];
    }]);
    [_probeController releaseCall:2 forName:@"depart-refresh-local.wav"];
    [self waitForExpectations:@[metadataReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse([_controller operationForLastPathComponent:@"depart-refresh-local.wav"].started,
                   @"a refresh that finds the file local settles without its operation");
    XCTAssertEqual([_probeController callCountForName:@"depart-refresh-local.wav"], 2u);
}

- (void)testForegroundDepartureDuringRefreshYieldsADatalessPassenger {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @YES] forName:@"depart-refresh-cloud.wav"];
    [_probeController gateCall:2 forName:@"depart-refresh-cloud.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"depart-refresh-cloud-blocker.wav"
                    role:VibeAudioFileMaterializationRolePrefetch
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    AudioFileMaterializationRequestToken *foreground =
            [self requestName:@"depart-refresh-cloud.wav"
                    role:VibeAudioFileMaterializationRolePrefetch
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {}];
    XCTestExpectation *metadataYielded =
            [self expectationWithDescription:@"dataless metadata passenger yielded"];
    __unused AudioFileMaterializationRequestToken *metadata =
            [self requestName:@"depart-refresh-cloud.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [metadataYielded fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    [[_controller operationForLastPathComponent:@"depart-refresh-cloud-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2
                                              forName:@"depart-refresh-cloud.wav"]);

    [foreground cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return ![self->_coordinator isForegroundTransferActive];
    }]);
    [_probeController releaseCall:2 forName:@"depart-refresh-cloud.wav"];
    [self waitForExpectations:@[metadataYielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u,
                   @"a yielded refresh must not enter its operation");
    XCTAssertEqual([_probeController callCountForName:@"depart-refresh-cloud.wav"], 2u);
}

- (void)testCancellingEveryWaiterDuringRefreshDrainsTheReservedLane {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @YES] forName:@"cancel-refresh.wav"];
    [_probeController gateCall:2 forName:@"cancel-refresh.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"cancel-refresh-blocker.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *cancelledSilent =
            [self expectationWithDescription:@"cancelled refresh silent"];
    cancelledSilent.inverted = YES;
    AudioFileMaterializationRequestToken *target =
            [self requestName:@"cancel-refresh.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [cancelledSilent fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);

    [[_controller operationForLastPathComponent:@"cancel-refresh-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2 forName:@"cancel-refresh.wav"]);
    VibeTestMaterializationOperation *refreshOperation =
            [_controller operationForLastPathComponent:@"cancel-refresh.wav"];
    XCTAssertNotNil(refreshOperation);
    XCTAssertFalse(refreshOperation.started);

    [target cancel];
    XCTAssertTrue([self waitForCondition:^BOOL{
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
                [self->_coordinator stateSnapshotForTesting];
        return refreshOperation.cancellationCount == 1 && snapshot.waiterCount == 0;
    }]);
    VibeAudioFileMaterializationCoordinatorSnapshot refreshing =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(refreshing.claimCount, 1u);
    XCTAssertEqual(refreshing.backgroundRunningCount, 1u,
                   @"the gated refresh still owns its reserved lane");

    [_probeController releaseCall:2 forName:@"cancel-refresh.wav"];
    XCTAssertTrue([self waitForCondition:^BOOL{
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
                [self->_coordinator stateSnapshotForTesting];
        return snapshot.claimCount == 0 && snapshot.waiterCount == 0
                && snapshot.backgroundRunningCount == 0
                && snapshot.backgroundPendingCount == 0
                && snapshot.datalessProbesInFlight == 0;
    }]);
    XCTAssertFalse(refreshOperation.started,
                   @"a refresh with no waiters must never enter its operation");
    [self waitForExpectations:@[cancelledSilent] timeout:0.1];
}

- (void)testForegroundRiseDuringRefreshYieldsFreshDatalessMetadata {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @YES] forName:@"rise-refresh-cloud.wav"];
    [_probeController gateCall:2 forName:@"rise-refresh-cloud.wav"];
    [_probeController gateCall:1 forName:@"rise-refresh-pick.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"rise-refresh-cloud-blocker.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *metadataYielded =
            [self expectationWithDescription:@"refreshed metadata yielded"];
    __unused AudioFileMaterializationRequestToken *metadata =
            [self requestName:@"rise-refresh-cloud.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [metadataYielded fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    [[_controller operationForLastPathComponent:@"rise-refresh-cloud-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2
                                              forName:@"rise-refresh-cloud.wav"]);
    VibeTestMaterializationOperation *refreshOperation =
            [_controller operationForLastPathComponent:@"rise-refresh-cloud.wav"];

    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback =
            [self requestName:@"rise-refresh-pick.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:1
                                              forName:@"rise-refresh-pick.wav"]);
    XCTAssertTrue([_coordinator isForegroundTransferActive]);

    [_probeController releaseCall:2 forName:@"rise-refresh-cloud.wav"];
    [self waitForExpectations:@[metadataYielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(refreshOperation.started);
    XCTAssertEqual(refreshOperation.cancellationCount, 1u);
    XCTAssertEqual([_probeController callCountForName:@"rise-refresh-cloud.wav"], 2u);
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"rise-refresh-cloud.wav"]]);
    XCTAssertTrue([_coordinator isForegroundTransferActive]);

    [_probeController releaseCall:1 forName:@"rise-refresh-pick.wav"];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    [[_controller operationForLastPathComponent:@"rise-refresh-pick.wav"]
            completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testForegroundRiseDuringRefreshPassesFreshLocalMetadata {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @NO] forName:@"rise-refresh-local.wav"];
    [_probeController gateCall:2 forName:@"rise-refresh-local.wav"];
    [_probeController gateCall:1 forName:@"rise-refresh-local-pick.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"rise-refresh-local-blocker.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *metadataReady =
            [self expectationWithDescription:@"refreshed local metadata ready"];
    __unused AudioFileMaterializationRequestToken *metadata =
            [self requestName:@"rise-refresh-local.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [metadataReady fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    [[_controller operationForLastPathComponent:@"rise-refresh-local-blocker.wav"]
            completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2
                                              forName:@"rise-refresh-local.wav"]);

    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback =
            [self requestName:@"rise-refresh-local-pick.wav"
                    role:VibeAudioFileMaterializationRolePlayback
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:1
                                              forName:@"rise-refresh-local-pick.wav"]);
    XCTAssertTrue([_coordinator isForegroundTransferActive]);

    [_probeController releaseCall:2 forName:@"rise-refresh-local.wav"];
    [self waitForExpectations:@[metadataReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    VibeTestMaterializationOperation *localOperation =
            [_controller operationForLastPathComponent:@"rise-refresh-local.wav"];
    XCTAssertFalse(localOperation.started);
    XCTAssertEqual(localOperation.cancellationCount, 0u);
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"rise-refresh-local.wav"]]);
    XCTAssertEqual([_probeController callCountForName:@"rise-refresh-local.wav"], 2u);
    XCTAssertTrue([_coordinator isForegroundTransferActive]);

    [_probeController releaseCall:1 forName:@"rise-refresh-local-pick.wav"];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    [[_controller operationForLastPathComponent:@"rise-refresh-local-pick.wav"]
            completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:VIBE_TEST_HANG_TIMEOUT];
}

#pragma mark - The foreground hold and local files

// The foreground hold derives from the claim table: registration preempts
// running metadata-only dataless work, new metadata requests yield while it is
// live, and its settlement is the release, so no external edge can be missed.
- (void)testAForegroundClaimPreemptsAndSuspendsMetadataOnlyWork {
    [_probeController gateCall:1 forName:@"user-pick.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *yielded = [self expectationWithDescription:@"running yielded"];
    __block NSUInteger deliveries = 0;
    __unused AudioFileMaterializationRequestToken *request = [self requestName:@"scan.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        deliveries++;
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [yielded fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *scanOperation =
            [_controller operationForLastPathComponent:@"scan.wav"];
    [scanOperation deferCancellationCompletion];
    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"user-pick.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    XCTAssertTrue([_probeController waitForCallCount:1 forName:@"user-pick.wav"]);
    [self waitForExpectations:@[yielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.totalCancellationCount, 1u);
    XCTAssertTrue([_coordinator stateSnapshotForTesting].foregroundTransferActive);

    XCTestExpectation *newYield = [self expectationWithDescription:@"new request yielded"];
    __unused AudioFileMaterializationRequestToken *blocked = [self requestName:@"scan.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [newYield fulfill];
    }];
    [self waitForExpectations:@[newYield] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([_coordinator stateSnapshotForTesting].requestsYielded, 2u,
                   @"requestsYielded never moved for the preempted and rejected requests");
    XCTAssertEqual([_probeController callCountForName:@"scan.wav"], 1u,
                   @"suspended metadata must not probe or join the retained claim");
    XCTAssertEqual(_controller.startedOperations.count, 1u);

    [scanOperation completeReady:NO];
    [_probeController releaseCall:1 forName:@"user-pick.wav"];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual([_probeController callCountForName:@"user-pick.wav"], 1u);
    [[_controller operationForLastPathComponent:@"user-pick.wav"] completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse([_coordinator stateSnapshotForTesting].foregroundTransferActive);
    dispatch_sync(_completionQueue, ^{});
    XCTAssertEqual(deliveries, 1u);
}

- (void)testForegroundRiseYieldsBothRunningAndPendingMetadataClaims {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *runningYielded = [self expectationWithDescription:@"running yielded"];
    __unused AudioFileMaterializationRequestToken *running = [self requestName:@"running-scan.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [runningYielded fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *pendingYielded = [self expectationWithDescription:@"pending yielded"];
    __unused AudioFileMaterializationRequestToken *pending = [self requestName:@"pending-scan.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [pendingYielded fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundPendingCount, 1u);

    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"picked.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    [self waitForExpectations:@[runningYielded, pendingYielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.totalCancellationCount, 1u);
    VibeAudioFileMaterializationCoordinatorSnapshot preempted =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(preempted.backgroundPendingCount, 0u);
    XCTAssertEqual(preempted.requestsYielded, 2u);
    XCTAssertTrue(preempted.foregroundTransferActive);

    XCTAssertTrue([_controller waitForStartedCount:2]);
    [[_controller operationForLastPathComponent:@"picked.wav"] completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testLocalFileStartsPastBackgroundCapacity {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    [_probeController setResults:@[@NO] forName:@"local.wav"];
    [self makeCoordinatorWithValues:values];

    __unused AudioFileMaterializationRequestToken *download = [self requestName:@"download.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    // The lane is at capacity with a transfer, but the local file needs no
    // run and must settle at once rather than park out its grace.
    XCTestExpectation *localReady = [self expectationWithDescription:@"local ready"];
    __unused AudioFileMaterializationRequestToken *local = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [localReady fulfill];
    }];
    [self waitForExpectations:@[localReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundPendingCount, 0u);
    XCTAssertEqual([_probeController callCountForName:@"local.wav"], 1u,
                   @"the fresh local answer must not get a start refresh");
    XCTAssertEqual(_controller.startedOperations.count, 1u,
                   @"the fresh local answer settles without an operation");
}

// A local read that never returns — a hung network share, a sleeping disk —
// must not hold the lane: nothing times a running read out, and the
// background lane is one wide, so every cloud row's metadata waited behind it.
- (void)testAStalledLocalRunLeavesTheLaneToTransfers {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    [self makeCoordinatorWithValues:values];

    // A cancelled run that lands Ready is readmitted local but not fresh, so
    // the readmission runs an operation, which can stall.
    AudioFileMaterializationRequestToken *cancelled = [self requestName:@"stalled-local.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *first = _controller.startedOperations.firstObject;
    [first deferCancellationCompletion];
    [cancelled cancel];
    __unused AudioFileMaterializationRequestToken *stalled = [self requestName:@"stalled-local.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    [first completeReady:YES];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundRunningCount, 0u,
                   @"a local run must not count against the lane");

    XCTestExpectation *downloadReady = [self expectationWithDescription:@"download ready"];
    __unused AudioFileMaterializationRequestToken *download = [self requestName:@"download.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [downloadReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:3],
                  @"the transfer waited behind a local read that never returned");
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot = [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.backgroundPendingCount, 0u);
    XCTAssertEqual(snapshot.backgroundRunningCount, 1u);
    [[_controller operationForLastPathComponent:@"download.wav"] completeReady:YES];
    [self waitForExpectations:@[downloadReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundRunningCount, 0u);
    [[_controller operationForLastPathComponent:@"stalled-local.wav"] completeReady:YES];
}

- (void)testBlockedDelayedRefreshLeavesStateResponsiveAndUsesItsFreshLocalAnswer {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 2;
    [_probeController setResults:@[@YES, @NO] forName:@"delayed-local.wav"];
    [_probeController gateCall:2 forName:@"delayed-local.wav"];
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerReady = [self expectationWithDescription:@"blocker ready"];
    __unused AudioFileMaterializationRequestToken *blocker =
            [self requestName:@"refresh-blocker.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        [blockerReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *targetReady = [self expectationWithDescription:@"target ready"];
    __unused AudioFileMaterializationRequestToken *target =
            [self requestName:@"delayed-local.wav"
                    role:VibeAudioFileMaterializationRoleMetadataScan
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [targetReady fulfill];
    }];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    XCTAssertEqual([_probeController callCountForName:@"delayed-local.wav"], 1u);

    [[_controller operationForLastPathComponent:@"refresh-blocker.wav"] completeReady:YES];
    [self waitForExpectations:@[blockerReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_probeController waitForCallCount:2 forName:@"delayed-local.wav"]);
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"delayed-local.wav"]]);

    dispatch_queue_t stateReadQueue = dispatch_queue_create(
            "com.vibe.tests.materialization.refresh-state", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *stateResponsive =
            [self expectationWithDescription:@"state responsive during refresh"];
    __block AudioLoadingConfiguration *configuration = nil;
    __block VibeAudioFileMaterializationCoordinatorSnapshot stateSnapshot;
    dispatch_async(stateReadQueue, ^{
        configuration = self->_coordinator.currentConfiguration;
        stateSnapshot = [self->_coordinator stateSnapshotForTesting];
        [stateResponsive fulfill];
    });

    @try {
        XCTWaiterResult responsive = [XCTWaiter waitForExpectations:@[stateResponsive]
                                                            timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertEqual(responsive, XCTWaiterResultCompleted,
                       @"a delayed refresh blocked coordinator state");
        if (responsive != XCTWaiterResultCompleted) {
            return;
        }
        XCTAssertNotNil(configuration);
        XCTAssertEqual(stateSnapshot.datalessProbesInFlight, 1u);
        XCTAssertEqual(stateSnapshot.backgroundRunningCount, 1u,
                       @"the outstanding refresh must retain its admitted lane");
        VibeTestMaterializationOperation *refreshOperation =
                [_controller operationForLastPathComponent:@"delayed-local.wav"];
        XCTAssertNotNil(refreshOperation);
        XCTAssertFalse(refreshOperation.started);
        XCTAssertEqual(_controller.startedOperations.count, 1u);
    }
    @finally {
        [_probeController releaseCall:2 forName:@"delayed-local.wav"];
    }

    [self waitForExpectations:@[targetReady] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([_probeController callCountForName:@"delayed-local.wav"], 2u);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundRunningCount, 0u,
                   @"a refresh that finds the file local hands its slot back");
    XCTAssertFalse([_controller operationForLastPathComponent:@"delayed-local.wav"].started,
                   @"a refresh that finds the file local settles without its operation");
    [self drainMainQueue];
    XCTAssertFalse([CloudTransferRegistry.sharedRegistry
            isTransferringURL:[self URLNamed:@"delayed-local.wav"]]);
}

- (void)testForegroundActivityPassesLocalFilesThrough {
    [_probeController setResults:@[@NO] forName:@"local.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"user-pick.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    XCTestExpectation *localReady = [self expectationWithDescription:@"local ready"];
    __unused AudioFileMaterializationRequestToken *local = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [localReady fulfill];
    }];
    [self waitForExpectations:@[localReady] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTestExpectation *datalessYield = [self expectationWithDescription:@"dataless yielded"];
    __unused AudioFileMaterializationRequestToken *dataless = [self requestName:@"cloud.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [datalessYield fulfill];
    }];
    [self waitForExpectations:@[datalessYield] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 1u);
    XCTAssertEqual([_probeController callCountForName:@"local.wav"], 1u);
    XCTAssertEqual([_probeController callCountForName:@"cloud.wav"], 1u);
}

- (void)testAForegroundRiseDoesNotYieldARunningLocalClaim {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

    // Readmitted local after a cancelled run landed Ready: the one local claim
    // that runs an operation, and so can be running when the foreground rises.
    AudioFileMaterializationRequestToken *cancelled = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    VibeTestMaterializationOperation *first = _controller.startedOperations.firstObject;
    [first deferCancellationCompletion];
    [cancelled cancel];
    XCTestExpectation *ready = [self expectationWithDescription:@"local ready"];
    __unused AudioFileMaterializationRequestToken *local = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [ready fulfill];
    }];
    [first completeReady:YES];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *localRun = _controller.startedOperations.lastObject;

    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"user-pick.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:3]);
    XCTAssertEqual(localRun.cancellationCount, 0u);
    XCTAssertEqual([_probeController callCountForName:@"local.wav"], 1u);

    [localRun completeReady:YES];
    [self waitForExpectations:@[ready] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Dataless metadata requests yield at entry while a foreground transfer is
// live, spending no grace or budget, so the second prefetch parks into an
// empty pending lane and the successor never queues behind the sweep.
- (void)testMetadataYieldsWhileAPrefetchRunsAndThePrefetchStartsNext {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 2;
    [self makeCoordinatorWithValues:values];

    XCTestExpectation *blockerDone = [self expectationWithDescription:@"blocker"];
    __unused AudioFileMaterializationRequestToken *blocker = [self requestName:@"blocker.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        [blockerDone fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    XCTestExpectation *metadataYielded = [self expectationWithDescription:@"metadata yielded"];
    __unused AudioFileMaterializationRequestToken *metadata = [self requestName:@"metadata-a.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [metadataYielded fulfill];
    }];
    XCTestExpectation *prefetchDone = [self expectationWithDescription:@"prefetch done"];
    __unused AudioFileMaterializationRequestToken *prefetch = [self requestName:@"next.wav"
            role:VibeAudioFileMaterializationRolePrefetch
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        [prefetchDone fulfill];
    }];
    [self waitForExpectations:@[metadataYielded] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    }]);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundPendingCount, 1u);

    [[_controller operationForLastPathComponent:@"blocker.wav"] completeReady:YES];
    [self waitForExpectations:@[blockerDone] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *second = _controller.startedOperations[1];
    XCTAssertEqualObjects(second.url.lastPathComponent, @"next.wav");
    XCTAssertEqual(second.role, VibeAudioFileMaterializationRolePrefetch);
    [second completeReady:YES];
    [self waitForExpectations:@[prefetchDone] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(_controller.startedOperations.count, 2u);
}

@end
