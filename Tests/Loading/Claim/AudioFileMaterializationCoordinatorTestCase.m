//
//  AudioFileMaterializationCoordinatorTestCase.m
//  VibeTests
//

#import "AudioFileMaterializationCoordinatorTestCase.h"

@implementation AudioFileMaterializationCoordinatorTestCase

- (void)setUp {
    [super setUp];
    _controller = [[VibeTestMaterializationController alloc] init];
    _probeController = [[VibeTestDatalessProbeController alloc] init];
    _completionQueue = dispatch_queue_create("com.vibe.tests.materialization", DISPATCH_QUEUE_SERIAL);
    _now = 100;
}

- (void)tearDown {
    [_probeController releaseAll];
    XCTAssertTrue([self waitForCondition:^BOOL{
        return [self->_coordinator datalessProbesInFlight] == 0;
    }], @"dataless probe work did not reconcile after releasing its gates");
    NSArray<NSString *> *stuckGates = _probeController.timedOutGates;
    XCTAssertEqual(stuckGates.count, 0u,
                   @"gated probe(s) %@ exceeded %.0fs — possible caller/state-path "
                   @"regression or missing test release",
                   stuckGates, (double)kProbeGateTimeout);
    [self assertAccountingSettles];
    [self drainMainQueue];
    _coordinator = nil;
    [super tearDown];
}

// Runs in teardown so it covers every test: a lane slot never given back is
// invisible to every other assertion and surfaces only as capacity that never
// returns. Drained pending claims mint fresh operations, so completeAll is
// inside the loop.
- (void)assertAccountingSettles {
    if (!_coordinator) {
        return;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot;
    do {
        [_controller completeAll];
        snapshot = [_coordinator stateSnapshotForTesting];
        if (snapshot.claimCount == 0 && snapshot.waiterCount == 0
                && snapshot.interactiveRunningCount == 0
                && snapshot.backgroundRunningCount == 0
                && snapshot.interactivePendingCount == 0
                && snapshot.backgroundPendingCount == 0
                && snapshot.handleRunCount == 0
                && snapshot.datalessProbesInFlight == 0
                && !snapshot.foregroundTransferActive
                && snapshot.handleOpensStarted == snapshot.handleOpensCompleted
                && _probeController.inFlightCount == 0) {
            return;
        }
        [NSThread sleepForTimeInterval:0.01];
    } while (deadline.timeIntervalSinceNow > 0);
    XCTFail(@"coordinator did not settle: claims %lu, waiters %lu, "
            @"interactive %lu/%lu, background %lu/%lu, handles %lu, foreground %d, "
            @"opens %llu started / %llu completed, coordinator probes %llu, "
            @"test probes %lu",
            (unsigned long)snapshot.claimCount,
            (unsigned long)snapshot.waiterCount,
            (unsigned long)snapshot.interactiveRunningCount,
            (unsigned long)snapshot.interactivePendingCount,
            (unsigned long)snapshot.backgroundRunningCount,
            (unsigned long)snapshot.backgroundPendingCount,
            (unsigned long)snapshot.handleRunCount,
            snapshot.foregroundTransferActive,
            snapshot.handleOpensStarted, snapshot.handleOpensCompleted,
            snapshot.datalessProbesInFlight,
            (unsigned long)_probeController.inFlightCount);
}

- (NSURL *)URLNamed:(NSString *)name {
    return [NSURL fileURLWithPath:[@"/tmp/vibe-materialization-tests" stringByAppendingPathComponent:name]];
}

- (AudioLoadingConfiguration *)configurationWithValues:(VibeAudioLoadingConfigurationValues)values {
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];
    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    return configuration;
}

- (void)makeCoordinatorWithValues:(VibeAudioLoadingConfigurationValues)values {
    AudioLoadingConfiguration *configuration = [self configurationWithValues:values];
    VibeTestMaterializationController *controller = _controller;
    VibeTestDatalessProbeController *probeController = _probeController;
    __weak AudioFileMaterializationCoordinatorTestCase *weakSelf = self;
    _coordinator = [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
            operationFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [controller operationForURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        return [probeController probeURL:url];
    } clock:^NSTimeInterval{
        AudioFileMaterializationCoordinatorTestCase *strongSelf = weakSelf;
        return strongSelf ? strongSelf->_now : 0;
    }];
}

- (BOOL)waitForCondition:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    do {
        if (condition()) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.005];
    } while (deadline.timeIntervalSinceNow > 0);
    return condition();
}

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"main queue drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (AudioFileMaterializationRequestToken *)requestName:(NSString *)name
                                                  role:(VibeAudioFileMaterializationRole)role
                                            completion:(VibeAudioFileMaterializationCompletion)completion {
    return [_coordinator materializeURL:[self URLNamed:name] role:role
                         completionQueue:_completionQueue completion:completion];
}

@end
