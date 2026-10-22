//
//  AudioTrackMetadataLoaderRetryTests.m
//

#import "AudioTrackMetadataLoaderTestCase.h"
#import "NSURL+Hash.h"
#import "VibeTestNegativeWindow.h"

#include <stdio.h>

// The loader's store, as far as a parse's cache write reaches it: it records
// the key each entry is filed under, and holds nothing.
@interface VibeRecordingMetadataStore : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *filedKeys;
@end

@implementation VibeRecordingMetadataStore {
    NSMutableArray<NSString *> *_filedKeys;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _filedKeys = [NSMutableArray array];
    }
    return self;
}

- (id)diskCache {
    return self;
}

- (void)setObject:(id)object forKey:(NSString *)key {
    @synchronized (self) {
        [_filedKeys addObject:key];
    }
}

- (void)removeObjectForKey:(NSString *)key {
}

- (NSArray<NSString *> *)filedKeys {
    @synchronized (self) {
        return [_filedKeys copy];
    }
}
@end

// Retries and their budgets, the foreground yield, admission and cancellation,
// and a parse of another version.
@interface AudioTrackMetadataLoaderRetryTests : AudioTrackMetadataLoaderTestCase
@end

@implementation AudioTrackMetadataLoaderRetryTests

#pragma mark - Retries

- (void)testFailedScanRetriesBehindUntriedRowsThenParsesOnce {
    VibeLoaderTestTrack *first = [self trackNamed:@"retry-first.wav"];
    VibeLoaderTestTrack *second = [self trackNamed:@"retry-second.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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
    // Parses run on several workers, so only the start order is promised.
    @synchronized (parseLock) {
        XCTAssertEqual(parsedURLs.count, 2u);
        XCTAssertEqualObjects([NSSet setWithArray:parsedURLs],
                              ([NSSet setWithObjects:first.url, second.url, nil]));
    }
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertTrue(second.metadata.parsedOK);
}

- (void)testFailedScanStopsAtItsAttemptBudgetWithoutParsing {
    VibeLoaderTestTrack *track = [self trackNamed:@"retry-exhausted.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:2 forURL:track.url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"attempt budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
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
    NSArray<VibeLoaderTestTrack *> *duplicates = @[
        [VibeLoaderTestTrack withURL:url],
        [VibeLoaderTestTrack withURL:url],
        [VibeLoaderTestTrack withURL:url],
    ];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:10 forURL:url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"shared path budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
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
    for (VibeLoaderTestTrack *track in duplicates) {
        XCTAssertNil(track.metadata);
    }
}

- (void)testSamePathScanAndPrioritySlotsSpendOneSharedPathBudget {
    NSURL *url = [self URLNamed:@"joined-duplicate-attempts.wav"];
    VibeLoaderTestTrack *scan = [VibeLoaderTestTrack withURL:url];
    VibeLoaderTestTrack *priority = [VibeLoaderTestTrack withURL:url];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
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
    VibeLoaderTestTrack *track = [self trackNamed:@"priority-exhausted-path.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"priority attempt started"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:0]
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) {
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
    VibeLoaderTestTrack *track = [self trackNamed:@"real-timer-scan.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"yielded-local.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"yielded-dataless.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"idle-kick-dataless.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"same-path-repeat.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"priority-generation.wav"];
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
    [PlaceholderFiles setDatalessProbe:^BOOL(NSURL *url) {
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

    VibeLoaderTestTrack *priority = [self trackNamed:@"yielded-cancel.wav"];
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled delayed record parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    NSMutableArray<dispatch_block_t> *retries = [self captureRetriesOf:loader];
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
        return retries.count == 1;
    } description:@"admission-exhausted record scheduled no retry"];
    NSDictionary *delayedState = [loader debugScanLaneState];
    XCTAssertEqualObjects(delayedState[@"pending"], (@[]));
    XCTAssertEqualObjects(delayedState[@"delayed"], (@[@"delayed.wav"]));
    XCTAssertEqualObjects(delayedState[@"inFlight"], @NO);
    XCTAssertEqualObjects(delayedState[@"stageOneFinished"], @YES);
    [loader cancel];
    [pending cancel];
    [running cancel];

    // The retry's edge, fired after the cancel.
    XCTAssertEqual(retries.count, 1u);
    dispatch_block_t retry = retries.firstObject;
    if (retry) retry();
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        parseCount++;
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    NSMutableArray<dispatch_block_t> *retries = [self captureRetriesOf:loader];
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

    VibeLoaderTestTrack *target = [self trackNamed:@"retry-after-admission.wav"];
    [loader load:@[target]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsAdmissionExhausted == 1;
    } description:@"loader request was not admission exhausted"];
    [self waitForCondition:^BOOL{
        return retries.count == 1;
    } description:@"admission-exhausted record scheduled no retry"];
    XCTAssertTrue([[loader debugScanLaneState][@"delayed"]
            containsObject:target.url.lastPathComponent]);

    controller.allStartsExpectation =
            [self expectationWithDescription:@"delayed retry started"];
    [pending cancel];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 0;
    } description:@"cancelled pending claim retained its capacity"];
    // The retry's edge, fired once the capacity it needs is free.
    XCTAssertEqual(retries.count, 1u);
    dispatch_block_t retry = retries.firstObject;
    if (retry) retry();
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
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

#pragma mark - Another version

// A local file of the given size, so its cache key is real.
- (NSURL *)localFileNamed:(NSString *)name bytes:(NSUInteger)length {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_testRootURL
            withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *url = [self URLNamed:name];
    XCTAssertTrue([[NSMutableData dataWithLength:length] writeToURL:url atomically:NO]);
    [self markLocal:url];
    return url;
}

// What a download that installs another version does: the file moves to
// another size under its URL, and every memoized key is retired.
- (void)replaceFileAt:(NSURL *)url withBytes:(NSUInteger)length {
    NSURL *next = [self URLNamed:@"next.partial"];
    XCTAssertTrue([[NSMutableData dataWithLength:length] writeToURL:next atomically:NO]);
    XCTAssertEqual(rename(next.fileSystemRepresentation, url.fileSystemRepresentation), 0);
    [NSURL invalidateMemoizedCacheKeys];
}

// A parse that completes after its file was replaced by another version is
// stale: it is neither installed, delivered nor filed. The row parses again
// under the new key, and the new version's tags are installed and filed.
- (void)testAParseOfAReplacedVersionInstallsNothingAndTheRowParsesAgain {
    NSURL *url = [self localFileNamed:@"replaced.mp3" bytes:1000];
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    NSString *oldKey = [url cacheKey];
    VibeRecordingMetadataStore *store = [[VibeRecordingMetadataStore alloc] init];
    _owner.metadataCache = store;
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation = [self expectationWithDescription:@"new version delivered"];
    XCTestExpectation *firstParseEntered = [self expectationWithDescription:@"first parse entered"];
    dispatch_semaphore_t firstParseGate = dispatch_semaphore_create(0);
    __block NSUInteger parses = 0;
    AudioTrackMetadataLoader *loader = [self loaderWithController:
            [[VibeMetadataLoaderOperationController alloc] init]
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        NSUInteger parse;
        @synchronized (store) {
            parse = ++parses;
        }
        if (parse == 1) {
            [firstParseEntered fulfill];
            dispatch_semaphore_wait(firstParseGate, DISPATCH_TIME_FOREVER);
            return VibeLoaderTestMetadataResult(YES, @"old version");
        }
        return VibeLoaderTestMetadataResult(YES, @"new version");
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[firstParseEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self replaceFileAt:url withBytes:2000];
    NSString *newKey = [url cacheKey];
    XCTAssertNotEqualObjects(newKey, oldKey);
    dispatch_semaphore_signal(firstParseGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kVibeTestNegativeWindow]];

    @synchronized (store) {
        XCTAssertEqual(parses, 2u, @"the stale parse, then the new version's");
    }
    XCTAssertEqualObjects([(VibeLoaderTestMetadata *)track.metadata marker], @"new version");
    XCTAssertEqualObjects(track.metadata.cacheKey, newKey);
    XCTAssertEqual(delegate.deliveredMetadata.count, 1u, @"the stale parse delivered nothing");
    XCTAssertEqual(delegate.deliveredMetadata.firstObject, track.metadata);
    XCTAssertEqualObjects(store.filedKeys, (@[newKey]), @"the stale parse filed nothing");
}

// Retired memos alone are no new version: the key read again at completion
// is the one the parse was looked up under, so it installs and files once.
- (void)testAParseOfAnUnchangedFileInstallsOnceTheMemosAreRetired {
    NSURL *url = [self localFileNamed:@"unchanged.mp3" bytes:1000];
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    VibeRecordingMetadataStore *store = [[VibeRecordingMetadataStore alloc] init];
    _owner.metadataCache = store;
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation = [self expectationWithDescription:@"delivered"];
    XCTestExpectation *parseEntered = [self expectationWithDescription:@"parse entered"];
    dispatch_semaphore_t parseGate = dispatch_semaphore_create(0);
    __block NSUInteger parses = 0;
    AudioTrackMetadataLoader *loader = [self loaderWithController:
            [[VibeMetadataLoaderOperationController alloc] init]
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        @synchronized (store) {
            parses++;
        }
        [parseEntered fulfill];
        dispatch_semaphore_wait(parseGate, DISPATCH_TIME_FOREVER);
        return VibeLoaderTestMetadataResult(YES, @"unchanged");
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[parseEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [NSURL invalidateMemoizedCacheKeys];
    dispatch_semaphore_signal(parseGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kVibeTestNegativeWindow]];

    @synchronized (store) {
        XCTAssertEqual(parses, 1u, @"installed, not parsed again");
    }
    XCTAssertEqualObjects([(VibeLoaderTestMetadata *)track.metadata marker], @"unchanged");
    XCTAssertEqualObjects(track.metadata.cacheKey, [url cacheKey]);
    XCTAssertEqual(delegate.deliveredMetadata.count, 1u);
    XCTAssertEqualObjects(store.filedKeys, (@[[url cacheKey]]));
}

// A new version clears what the row installed. A row holding the old
// version's tags parses again in the next sweep, and the new version's tags
// replace them. A row whose file kept its version is not parsed again.
- (void)testARowHoldingAnOldVersionsTagsParsesAgainInTheNextSweep {
    NSURL *replacedURL = [self localFileNamed:@"rekeyed.mp3" bytes:1000];
    NSURL *keptURL = [self localFileNamed:@"kept.mp3" bytes:1000];
    VibeLoaderTestTrack *replaced = [VibeLoaderTestTrack withURL:replacedURL];
    VibeLoaderTestTrack *kept = [VibeLoaderTestTrack withURL:keptURL];
    NSObject *parseLock = [[NSObject alloc] init];
    NSMutableArray<NSString *> *parsed = [NSMutableArray array];
    VibeAudioTrackMetadataFileParser parser = ^AudioTrackMetadata *(NSURL *url) {
        NSUInteger count;
        @synchronized (parseLock) {
            [parsed addObject:url.lastPathComponent];
            count = parsed.count;
        }
        return VibeLoaderTestMetadataResult(YES, [NSString stringWithFormat:@"%@ %lu",
                url.lastPathComponent, (unsigned long)count]);
    };
    VibeMetadataLoaderDelegate *firstDelegate = [[VibeMetadataLoaderDelegate alloc] init];
    firstDelegate.deliveryExpectation = [self expectationWithDescription:@"first sweep delivered"];
    firstDelegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *first = [self loaderWithController:
            [[VibeMetadataLoaderOperationController alloc] init]
            configuration:[self testConfiguration]
            delegate:firstDelegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
            fileParser:parser];
    [first load:@[replaced, kept]];
    [self waitForExpectations:@[firstDelegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    AudioTrackMetadata *keptTags = kept.metadata;
    AudioTrackMetadata *oldTags = replaced.metadata;
    XCTAssertTrue(oldTags.parsedOK);

    [self replaceFileAt:replacedURL withBytes:2000];
    VibeMetadataLoaderDelegate *secondDelegate = [[VibeMetadataLoaderDelegate alloc] init];
    secondDelegate.deliveryExpectation = [self expectationWithDescription:@"next sweep delivered"];
    AudioTrackMetadataLoader *second = [self loaderWithController:
            [[VibeMetadataLoaderOperationController alloc] init]
            configuration:[self testConfiguration]
            delegate:secondDelegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *candidate) { return nil; }
            fileParser:parser];
    [second load:@[replaced, kept]];
    [self waitForExpectations:@[secondDelegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kVibeTestNegativeWindow]];

    @synchronized (parseLock) {
        XCTAssertEqual(parsed.count, 3u, @"only the replaced file parses again");
        XCTAssertEqualObjects(parsed.lastObject, @"rekeyed.mp3");
    }
    XCTAssertNotEqual(replaced.metadata, oldTags);
    XCTAssertEqualObjects([(VibeLoaderTestMetadata *)replaced.metadata marker], @"rekeyed.mp3 3");
    XCTAssertEqualObjects(replaced.metadata.cacheKey, [replacedURL cacheKey]);
    XCTAssertEqualObjects(secondDelegate.deliveredTracks, (@[replaced]));
    XCTAssertEqual(kept.metadata, keptTags, @"an unchanged file keeps its tags");
}

@end
