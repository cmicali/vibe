//
//  AudioTrackMetadataLoaderRetryTests.m
//

#import "AudioTrackMetadataLoaderTestCase.h"

// Retries and their budgets, the foreground yield, admission and cancellation.
@interface AudioTrackMetadataLoaderRetryTests : AudioTrackMetadataLoaderTestCase
@end

@implementation AudioTrackMetadataLoaderRetryTests

#pragma mark - Retries

- (void)testFailedScanRetriesBehindUntriedRowsThenParsesOnce {
    AudioTrack *first = [self trackNamed:@"retry-first.wav"];
    AudioTrack *second = [self trackNamed:@"retry-second.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:1 forURL:first.url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"failed scan retried"];
    controller.allStartsExpectation.expectedFulfillmentCount = 3;
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both retry rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    NSObject *parseLock = [[NSObject alloc] init];
    NSMutableArray<NSURL *> *parsedURLs = [NSMutableArray array];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        @synchronized (parseLock) {
            [parsedURLs addObject:url];
        }
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[first, second]];
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs,
            (@[first.url, second.url, first.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    @synchronized (parseLock) {
        XCTAssertEqualObjects(parsedURLs, (@[second.url, first.url]));
    }
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertTrue(second.metadata.parsedOK);
}

- (void)testFailedScanStopsAtItsAttemptBudgetWithoutParsing {
    AudioTrack *track = [self trackNamed:@"retry-exhausted.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:2 forURL:track.url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"attempt budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"an exhausted materialization must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 2;
    } description:@"second failed attempt did not settle"];
    [self waitForDelay:0.02];

    XCTAssertEqual(controller.startedURLs.count, 2u);
    XCTAssertNil(track.metadata);
    XCTAssertEqualObjects(_owner.parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
}

- (void)testDuplicateRowsShareOnePathAttemptBudget {
    NSURL *url = [self URLNamed:@"duplicate-exhausted-path.wav"];
    NSArray<AudioTrack *> *duplicates = @[
        [AudioTrack withURL:url],
        [AudioTrack withURL:url],
        [AudioTrack withURL:url],
    ];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:10 forURL:url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"shared path budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"duplicates on an exhausted path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:duplicates];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 2;
    } description:@"duplicate path did not settle its shared attempt budget"];
    [self waitForCondition:^BOOL{
        NSDictionary *scan = [loader debugScanLaneState];
        return [scan[@"pending"] count] == 0 && ![scan[@"inFlight"] boolValue];
    } description:@"exhausted path did not drop its duplicate records"];
    [self waitForDelay:0.05];

    XCTAssertEqual(controller.startedURLs.count, 2u,
            @"duplicate rows must not multiply a per-path attempt budget");
    for (AudioTrack *track in duplicates) {
        XCTAssertNil(track.metadata);
    }
}

- (void)testSamePathScanAndPrioritySlotsSpendOneSharedPathBudget {
    NSURL *url = [self URLNamed:@"joined-duplicate-attempts.wav"];
    AudioTrack *scan = [AudioTrack withURL:url];
    AudioTrack *priority = [AudioTrack withURL:url];
    dispatch_semaphore_t holdDecisionGate = dispatch_semaphore_create(0);
    XCTestExpectation *holdDecisionReached =
            [self expectationWithDescription:@"first duplicate hold decided"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"first duplicate scan held"];
    [controller setAfterFailureCheck:^{
        [holdDecisionReached fulfill];
        long waitResult = dispatch_semaphore_wait(holdDecisionGate,
                dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        XCTAssertEqual(waitResult, 0L, @"hold decision gate timed out");
    }];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:2]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"duplicates on an exhausted path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    @try {
        // A listed duplicate would share the scan's record; one the sweep
        // never listed mints its own beside it.
        [loader load:@[scan]];
        [self waitForExpectations:@[
            controller.firstStartExpectation, holdDecisionReached
        ] timeout:VIBE_TEST_HANG_TIMEOUT];
        [loader prioritizeTrack:priority];
        [self waitForCondition:^BOOL{
            NSDictionary *lane = [loader debugPriorityLaneState];
            return [lane[@"pending"] count] == 1
                    && [lane[@"liveTokens"] unsignedIntegerValue] == 0
                    && [coordinator stateSnapshotForTesting].waiterCount == 1;
        } description:@"priority did not stay behind the active same-path scan claim"];

        [controller failNextStarts:10 forURL:url];
        controller.blocksUntilCancelled = NO;
        [controller completeFirstFailed];
    }
    @finally {
        [controller setAfterFailureCheck:nil];
        dispatch_semaphore_signal(holdDecisionGate);
    }
    [self waitForCondition:^BOOL{
        return controller.startedURLs.count >= 3;
    } description:@"remaining physical retries did not start"];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 3;
    } description:@"three physical provider failures did not spend three attempts"];
    [self waitForCondition:^BOOL{
        NSDictionary *priority = [loader debugPriorityLaneState];
        NSDictionary *scan = [loader debugScanLaneState];
        return [priority[@"pending"] count] == 0
                && ![priority[@"inFlight"] boolValue]
                && [scan[@"pending"] count] == 0
                && ![scan[@"inFlight"] boolValue];
    } description:@"exhausted path did not drop its records from both slots"];
    [self waitForDelay:0.05];

    XCTAssertEqual(controller.startedURLs.count, 3u,
            @"separate slot submissions must not multiply the shared path budget");
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
    XCTAssertNil(scan.metadata);
    XCTAssertNil(priority.metadata);
}

- (void)testNewPriorityEdgeCannotResetAnExhaustedPathBudget {
    AudioTrack *track = [self trackNamed:@"priority-exhausted-path.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"priority attempt started"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:0]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"an exhausted priority path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader prioritizeTrack:track];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:track];
    [controller completeFirstFailed];

    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 1;
    } description:@"failed priority attempt did not spend its path budget"];
    [self waitForCondition:^BOOL{
        NSDictionary *priority = [loader debugPriorityLaneState];
        return [priority[@"pending"] count] == 0
                && ![priority[@"inFlight"] boolValue]
                && [priority[@"liveTokens"] unsignedIntegerValue] == 0;
    } description:@"exhausted priority record did not settle out of its slot"];
    [self waitForDelay:0.05];

    XCTAssertEqual(controller.startedURLs.count, 1u);
    XCTAssertNil(track.metadata);
}

#pragma mark - Foreground yield

- (void)testProductionGatedTimerReopensADatalessScanAfterForegroundRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *cacheChecked =
            [self expectationWithDescription:@"scan stage one checked cache"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"gated scan parsed"];
    NSObject *cacheLock = [[NSObject alloc] init];
    // Both stamped on the loader's own threads, on the gated timer's clock, so
    // a descheduled test thread moves neither: the gate arms after the cache
    // check, and nothing but its tick, a second out, may reopen the scan.
    __block uint64_t cacheCheckedAt = 0;
    __block uint64_t scanStartedAt = 0;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        @synchronized (cacheLock) {
            if (cacheCheckedAt == 0) {
                cacheCheckedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                [cacheChecked fulfill];
            }
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    controller.startObserver = ^(NSURL *url, VibeAudioFileMaterializationRole role) {
        if (role == VibeAudioFileMaterializationRoleMetadataScan) {
            scanStartedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        }
    };
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-real-gate", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-real-timer.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"timer admitted gated scan"];
    AudioTrack *track = [self trackNamed:@"real-timer-scan.wav"];
    [loader load:@[track]];
    [self waitForExpectations:@[cacheChecked] timeout:VIBE_TEST_HANG_TIMEOUT];
    // Polled: a scan whose pick comes after the release was never gated, and
    // starts at once.
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"gatedRepickPending"] boolValue];
    } description:@"scan was not gated behind the foreground"];
    [self waitForDelay:0.1];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"dataless scan entered while foreground was active");

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertGreaterThanOrEqual(scanStartedAt, cacheCheckedAt + NSEC_PER_SEC,
            @"scan reopened before the production gated timer fired");
    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-real-timer.wav"], track.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
}

- (void)testYieldedPriorityWaitsWithoutSpinThenRetriesOnceWhenLocal {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"priority parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-local", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-local.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"yielded-local.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];
    for (NSUInteger kick = 0; kick < 8; kick++) {
        [loader setNeighborhoodURLs:@[priority.url]];
    }
    [self waitForDelay:0.05];
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u,
            @"yielded priority record spun while the foreground was active");
    XCTAssertEqual(controller.startedURLs.count, 1u);

    [self markLocal:priority.url];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader recheckForegroundGate];
    [self waitForExpectations:@[parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:0.02];

    // The retry found the file local, which settles with no operation.
    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-local.wav"]
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testYieldedPriorityDemotesToOrdinaryScanWhenStillDatalessAtRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"demoted record parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-demote", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-demote.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"yielded-dataless.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"demoted scan started"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader recheckForegroundGate];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:0.02];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-demote.wav"], priority.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testUnrelatedIdleKickJudgesYieldBeforePickingPriorityAgain {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"idle-demoted record parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-idle-kick", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-idle-kick.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"idle-kick-dataless.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [[loader debugPriorityLaneState][@"yieldedUnderHold"]
                        unsignedIntegerValue] == 1;
    } description:@"priority record did not park after yielding"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"idle kick started ordinary scan"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader setNeighborhoodURLs:@[priority.url]];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testRepeatPriorityEdgeJoinsNewSamePathForegroundClaim {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"first foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"same-path waiter parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-same-path-repeat", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *firstCompleted =
            [self expectationWithDescription:@"first foreground completed"];
    __unused AudioFileMaterializationRequestToken *firstToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-before-same-path.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [firstCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"same-path-repeat.wav"];
    [loader prioritizeTrack:priority];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [[loader debugPriorityLaneState][@"yieldedUnderHold"]
                        unsignedIntegerValue] == 1;
    } description:@"first priority edge did not yield and park"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"same-path playback started"];
    [controller completeFirstReady];
    [self waitForExpectations:@[firstCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTestExpectation *samePathCompleted =
            [self expectationWithDescription:@"same-path playback completed"];
    __unused AudioFileMaterializationRequestToken *samePathToken = [coordinator
            materializeURL:priority.url
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [samePathCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    [loader prioritizeTrack:priority];
    [self waitForCondition:^BOOL{
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
                [coordinator stateSnapshotForTesting];
        NSDictionary *state = [loader debugPriorityLaneState];
        return snapshot.waiterCount == 2
                && [state[@"inFlight"] boolValue]
                && [state[@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"repeat edge did not join the active same-path claim"];

    [controller completeLastReady];
    [self waitForExpectations:@[samePathCompleted, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRolePlayback),
    ]), @"the metadata waiter must not start another provider operation");
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.requestsYielded, 1u);
    XCTAssertEqual(snapshot.requestsReady, 3u,
            @"both foreground owners and the metadata waiter must settle Ready");
}

- (void)testFreshPriorityMarkSurvivesOlderYieldJudgementProbe {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"fresh priority parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-priority-generation", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-priority-generation.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"priority-generation.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugPriorityLaneState];
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [state[@"yieldedUnderHold"] unsignedIntegerValue] == 1;
    } description:@"priority request did not park after yielding"];

    dispatch_semaphore_t probeGate = dispatch_semaphore_create(0);
    XCTestExpectation *probeEntered =
            [self expectationWithDescription:@"old mark locality probe entered"];
    NSObject *probeLock = [[NSObject alloc] init];
    __block BOOL shouldGateProbe = YES;
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
        BOOL gate = NO;
        if ([url isEqual:priority.url]) {
            @synchronized (probeLock) {
                gate = shouldGateProbe;
                shouldGateProbe = NO;
            }
        }
        if (gate) {
            [probeEntered fulfill];
            dispatch_semaphore_wait(probeGate, DISPATCH_TIME_FOREVER);
        }
        return YES;
    }];

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted, probeEntered] timeout:VIBE_TEST_HANG_TIMEOUT];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"fresh priority mark retried"];
    [loader prioritizeTrack:priority];
    dispatch_semaphore_signal(probeGate);
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-priority-generation.wav"], priority.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
}

- (void)testCancellingYieldedPriorityDropsItBeforeForegroundRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled yielded record parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-cancel", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-cancel.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    AudioTrack *priority = [self trackNamed:@"yielded-cancel.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];
    [loader cancel];

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:1.05];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"cancelled yielded record was readmitted by the gated timer");
}

#pragma mark - Admission and cancellation

- (void)testCancellingAdmissionDelayedRecordPreventsItsRetry {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 1;
    values.metadataRetryCount = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"lane occupied"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled delayed record parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-delay-cancel", DISPATCH_QUEUE_SERIAL);
    __unused AudioFileMaterializationRequestToken *running = [coordinator
            materializeURL:[self URLNamed:@"running-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    AudioFileMaterializationRequestToken *pending = [coordinator
            materializeURL:[self URLNamed:@"pending-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    } description:@"background pending slot was not occupied"];

    [loader load:@[[self trackNamed:@"delayed.wav"]]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsAdmissionExhausted == 1;
    } description:@"loader request was not admission exhausted"];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"delayed"] containsObject:@"delayed.wav"];
    } description:@"admission-exhausted record did not enter the delayed set"];
    NSDictionary *delayedState = [loader debugScanLaneState];
    XCTAssertEqualObjects(delayedState[@"pending"], (@[]));
    XCTAssertEqualObjects(delayedState[@"delayed"], (@[@"delayed.wav"]));
    XCTAssertEqualObjects(delayedState[@"inFlight"], @NO);
    XCTAssertEqualObjects(delayedState[@"stageOneFinished"], @YES);
    [loader cancel];
    [pending cancel];
    [running cancel];

    [self waitForDelay:0.35];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"cancelled delayed record retried after its eligibility edge");
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsAdmissionExhausted, 1u);
}

- (void)testAdmissionDelayedRecordRetriesOnceAfterCapacityFreesAndPublishes {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 1;
    values.metadataRetryCount = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"background lane occupied"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"retried metadata published"];
    __block NSUInteger parseCount = 0;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        parseCount++;
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-delay-retry", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *runningCompleted =
            [self expectationWithDescription:@"running claim completed"];
    __unused AudioFileMaterializationRequestToken *running = [coordinator
            materializeURL:[self URLNamed:@"retry-running-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [runningCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    AudioFileMaterializationRequestToken *pending = [coordinator
            materializeURL:[self URLNamed:@"retry-pending-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    } description:@"background pending slot was not occupied"];

    AudioTrack *target = [self trackNamed:@"retry-after-admission.wav"];
    [loader load:@[target]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsAdmissionExhausted == 1;
    } description:@"loader request was not admission exhausted"];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"delayed"]
                containsObject:target.url.lastPathComponent];
    } description:@"admission-exhausted record did not enter the delayed set"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"delayed retry started"];
    [pending cancel];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 0;
    } description:@"cancelled pending claim retained its capacity"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[runningCompleted] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual(parseCount, 1u);
    XCTAssertTrue(target.metadata.parsedOK);
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"retry-running-background.wav"], target.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.requestsAdmissionExhausted, 1u);
    XCTAssertEqual(snapshot.requestsReady, 2u);
}

- (void)testCancellingReplacedLoaderDropsItsPendingRecordsAndToken {
    VibeMetadataLoaderOperationController *oldController =
            [[VibeMetadataLoaderOperationController alloc] init];
    oldController.blocksUntilCancelled = YES;
    oldController.firstStartExpectation = [self expectationWithDescription:@"old started"];
    oldController.cancellationExpectation = [self expectationWithDescription:@"old cancelled"];
    AudioTrackMetadataLoader *oldLoader = [self loaderWithController:oldController
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled loader parsed a track");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    [oldLoader load:@[
        [self trackNamed:@"old-zero.wav"],
        [self trackNamed:@"old-one.wav"],
        [self trackNamed:@"old-two.wav"],
    ]];
    [self waitForExpectations:@[oldController.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [oldLoader cancel];
    [self waitForExpectations:@[oldController.cancellationExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    VibeMetadataLoaderOperationController *newController =
            [[VibeMetadataLoaderOperationController alloc] init];
    newController.firstStartExpectation = [self expectationWithDescription:@"replacement started"];
    XCTestExpectation *replacementParsed = [self expectationWithDescription:@"replacement parsed"];
    AudioTrackMetadataLoader *replacement = [self loaderWithController:newController
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [replacementParsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    [replacement load:@[[self trackNamed:@"new.wav"]]];
    [self waitForExpectations:@[newController.firstStartExpectation, replacementParsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTestExpectation *oldCallbackDrained = [self expectationWithDescription:@"old callback drained"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [oldCallbackDrained fulfill];
    });
    [self waitForExpectations:@[oldCallbackDrained] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(oldController.startedURLs.count, 1u,
            @"cancelled loader admitted another pending record");
}

@end
