//
//  AudioFileMaterializationCoordinatorTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinatorInternal.h"

@class VibeTestMaterializationController;

@interface VibeTestMaterializationOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeTestMaterializationController *)controller;
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) VibeAudioFileMaterializationRole role;
@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly) NSUInteger cancellationCount;
- (void)deferCancellationCompletion;
- (void)completeReady:(BOOL)ready;
@end

@interface VibeTestMaterializationController : NSObject
- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role;
- (void)operationDidStart:(VibeTestMaterializationOperation *)operation;
- (BOOL)waitForStartedCount:(NSUInteger)count;
- (NSArray<VibeTestMaterializationOperation *> *)startedOperations;
- (VibeTestMaterializationOperation *)operationForLastPathComponent:(NSString *)name;
- (NSUInteger)totalCancellationCount;
- (void)completeAll;
@end

@implementation VibeTestMaterializationOperation {
    NSCondition *_condition;
    __weak VibeTestMaterializationController *_controller;
    BOOL _started;
    BOOL _finished;
    BOOL _ready;
    BOOL _defersCancellationCompletion;
    NSUInteger _cancellationCount;
}

- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeTestMaterializationController *)controller {
    self = [super init];
    if (self) {
        _url = url;
        _role = role;
        _controller = controller;
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    [_condition lock];
    _started = YES;
    [_condition broadcast];
    [_condition unlock];
    VibeTestMaterializationController *controller = _controller;
    [controller operationDidStart:self];

    [_condition lock];
    while (!_finished) {
        [_condition wait];
    }
    BOOL ready = _ready;
    [_condition unlock];
    if (!ready && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:NSUserCancelledError userInfo:nil];
    }
    return ready;
}

- (void)cancel {
    [_condition lock];
    _cancellationCount++;
    if (!_defersCancellationCompletion) {
        _finished = YES;
        _ready = NO;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)deferCancellationCompletion {
    [_condition lock];
    _defersCancellationCompletion = YES;
    [_condition unlock];
}

- (void)completeReady:(BOOL)ready {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = ready;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (BOOL)started {
    [_condition lock];
    BOOL started = _started;
    [_condition unlock];
    return started;
}

- (NSUInteger)cancellationCount {
    [_condition lock];
    NSUInteger count = _cancellationCount;
    [_condition unlock];
    return count;
}

@end

@implementation VibeTestMaterializationController {
    NSCondition *_condition;
    NSMutableArray<VibeTestMaterializationOperation *> *_operations;
    NSMutableArray<VibeTestMaterializationOperation *> *_startedOperations;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _operations = [NSMutableArray array];
        _startedOperations = [NSMutableArray array];
    }
    return self;
}

- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role {
    VibeTestMaterializationOperation *operation =
            [[VibeTestMaterializationOperation alloc] initWithURL:url role:role controller:self];
    [_condition lock];
    [_operations addObject:operation];
    [_condition broadcast];
    [_condition unlock];
    return operation;
}

- (void)operationDidStart:(VibeTestMaterializationOperation *)operation {
    [_condition lock];
    [_startedOperations addObject:operation];
    [_condition broadcast];
    [_condition unlock];
}

- (BOOL)waitForStartedCount:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    [_condition lock];
    while (_startedOperations.count < count) {
        if (![_condition waitUntilDate:deadline]) {
            [_condition unlock];
            return NO;
        }
    }
    [_condition unlock];
    return YES;
}

- (NSArray<VibeTestMaterializationOperation *> *)startedOperations {
    [_condition lock];
    NSArray *operations = [_startedOperations copy];
    [_condition unlock];
    return operations;
}

- (VibeTestMaterializationOperation *)operationForLastPathComponent:(NSString *)name {
    [_condition lock];
    VibeTestMaterializationOperation *found = nil;
    for (VibeTestMaterializationOperation *operation in _operations.reverseObjectEnumerator) {
        if ([operation.url.lastPathComponent isEqualToString:name]) {
            found = operation;
            break;
        }
    }
    [_condition unlock];
    return found;
}

- (NSUInteger)totalCancellationCount {
    [_condition lock];
    NSArray *operations = [_operations copy];
    [_condition unlock];
    NSUInteger count = 0;
    for (VibeTestMaterializationOperation *operation in operations) {
        count += operation.cancellationCount;
    }
    return count;
}

- (void)completeAll {
    [_condition lock];
    NSArray *operations = [_operations copy];
    [_condition unlock];
    for (VibeTestMaterializationOperation *operation in operations) {
        [operation completeReady:YES];
    }
}

@end

@interface AudioFileMaterializationCoordinatorTests : XCTestCase
@end

@implementation AudioFileMaterializationCoordinatorTests {
    VibeTestMaterializationController *_controller;
    AudioFileMaterializationCoordinator *_coordinator;
    dispatch_queue_t _completionQueue;
    NSTimeInterval _now;
    // Test URLs are fabricated paths, so the real stat would answer "local"
    // for all of them and every claim would bypass capacity. The injected
    // probe answers dataless unless the name is listed here.
    NSMutableSet<NSString *> *_localNames;
}

- (void)setUp {
    [super setUp];
    _controller = [[VibeTestMaterializationController alloc] init];
    _completionQueue = dispatch_queue_create("com.vibe.tests.materialization", DISPATCH_QUEUE_SERIAL);
    _now = 100;
    _localNames = [NSMutableSet set];
}

- (void)tearDown {
    [_controller completeAll];
    _coordinator = nil;
    [super tearDown];
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
    __weak AudioFileMaterializationCoordinatorTests *weakSelf = self;
    NSMutableSet<NSString *> *localNames = _localNames;
    _coordinator = [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
            operationFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [controller operationForURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        @synchronized (localNames) {
            return ![localNames containsObject:url.lastPathComponent];
        }
    } clock:^NSTimeInterval{
        AudioFileMaterializationCoordinatorTests *strongSelf = weakSelf;
        return strongSelf ? strongSelf->_now : 0;
    }];
}

- (AudioFileMaterializationRequestToken *)requestName:(NSString *)name
                                                  role:(VibeAudioFileMaterializationRole)role
                                            completion:(VibeAudioFileMaterializationCompletion)completion {
    return [_coordinator materializeURL:[self URLNamed:name] role:role
                         completionQueue:_completionQueue registered:nil completion:completion];
}

- (void)testSamePathRequestsAtomicallyJoinOneOperation {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    XCTestExpectation *scan = [self expectationWithDescription:@"scan ready"];
    XCTestExpectation *prefetch = [self expectationWithDescription:@"prefetch ready"];
    __unused AudioFileMaterializationRequestToken *first = [self requestName:@"same.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [scan fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
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
    XCTAssertEqual(_controller.startedOperations.count, 1u);

    [[_controller operationForLastPathComponent:@"same.wav"] completeReady:YES];
    [self waitForExpectations:@[scan, prefetch] timeout:2];
}

- (void)testRegistrationReturnsBeforeCompletionBeginsOnAConcurrentQueue {
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];
    dispatch_queue_t concurrentQueue = dispatch_queue_create(
            "com.vibe.tests.materialization.concurrent-delivery", DISPATCH_QUEUE_CONCURRENT);
    dispatch_semaphore_t allowRegistrationToReturn = dispatch_semaphore_create(0);
    dispatch_semaphore_t completionBegan = dispatch_semaphore_create(0);
    NSLock *eventsLock = [[NSLock alloc] init];
    NSMutableArray<NSString *> *events = [NSMutableArray array];
    XCTestExpectation *registrationBegan = [self expectationWithDescription:@"registration began"];
    XCTestExpectation *registrationReturned = [self expectationWithDescription:@"registration returned"];
    XCTestExpectation *completed = [self expectationWithDescription:@"completion"];
    registrationBegan.assertForOverFulfill = YES;
    completed.assertForOverFulfill = YES;

    __unused AudioFileMaterializationRequestToken *token = [_coordinator
            materializeURL:[self URLNamed:@"ordered.wav"]
            role:VibeAudioFileMaterializationRolePlayback
            completionQueue:concurrentQueue
            registered:^{
        [eventsLock lock];
        [events addObject:@"registration-began"];
        [eventsLock unlock];
        [registrationBegan fulfill];
        dispatch_semaphore_wait(allowRegistrationToReturn, DISPATCH_TIME_FOREVER);
        [eventsLock lock];
        [events addObject:@"registration-returned"];
        [eventsLock unlock];
        [registrationReturned fulfill];
    } completion:^(VibeAudioFileMaterializationResult result,
                   NSError *error, NSTimeInterval elapsed) {
        [eventsLock lock];
        [events addObject:@"completion"];
        [eventsLock unlock];
        dispatch_semaphore_signal(completionBegan);
        [completed fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    [self waitForExpectations:@[registrationBegan] timeout:2];
    [[_controller operationForLastPathComponent:@"ordered.wav"] completeReady:YES];

    long earlyCompletion = dispatch_semaphore_wait(completionBegan,
            dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
    XCTAssertNotEqual(earlyCompletion, 0,
            @"completion must not overlap a registration callback that has not returned");
    dispatch_semaphore_signal(allowRegistrationToReturn);
    [self waitForExpectations:@[registrationReturned, completed] timeout:2];

    [eventsLock lock];
    NSArray<NSString *> *delivered = [events copy];
    [eventsLock unlock];
    XCTAssertEqualObjects(delivered,
            (@[@"registration-began", @"registration-returned", @"completion"]));
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
    [second completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:2];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
    VibeAudioFileMaterializationCoordinatorSnapshot settled =
            [_coordinator stateSnapshotForTesting];
    XCTAssertEqual(settled.claimCount, 0u);
    XCTAssertEqual(settled.waiterCount, 0u);
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
    [self waitForExpectations:@[survivor] timeout:2];
    dispatch_sync(_completionQueue, ^{});
    XCTAssertEqual(cancelledDeliveries, 0u);
    XCTAssertEqual(_controller.totalCancellationCount, 0u);
}

// The C1 rule, derived: a playback claim's registration preempts running
// metadata-only dataless work, new metadata requests yield while it is live,
// and its settlement is the release — no external edge exists to miss.
- (void)testAForegroundClaimPreemptsAndSuspendsMetadataOnlyWork {
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
    XCTestExpectation *playbackReady = [self expectationWithDescription:@"playback ready"];
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"user-pick.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [playbackReady fulfill];
    }];
    [self waitForExpectations:@[yielded] timeout:2];
    XCTAssertEqual(_controller.totalCancellationCount, 1u);
    XCTAssertTrue([_coordinator stateSnapshotForTesting].foregroundTransferActive);

    XCTestExpectation *newYield = [self expectationWithDescription:@"new request yielded"];
    __unused AudioFileMaterializationRequestToken *blocked = [self requestName:@"other.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [newYield fulfill];
    }];
    [self waitForExpectations:@[newYield] timeout:2];
    // The scan's cancelled run plus the playback transfer, and nothing for
    // the yielded requests.
    XCTAssertEqual(_controller.startedOperations.count, 2u);
    [[_controller operationForLastPathComponent:@"user-pick.wav"] completeReady:YES];
    [self waitForExpectations:@[playbackReady] timeout:2];
    XCTAssertFalse([_coordinator stateSnapshotForTesting].foregroundTransferActive);
    dispatch_sync(_completionQueue, ^{});
    XCTAssertEqual(deliveries, 1u);
}

- (void)testLocalFileStartsPastBackgroundCapacity {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 1;
    [_localNames addObject:@"local.wav"];
    [self makeCoordinatorWithValues:values];

    __unused AudioFileMaterializationRequestToken *download = [self requestName:@"download.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);

    // The lane is at capacity with a transfer, but the local file's run is a
    // no-op and must start immediately rather than park out its grace.
    XCTestExpectation *localReady = [self expectationWithDescription:@"local ready"];
    __unused AudioFileMaterializationRequestToken *local = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [localReady fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundPendingCount, 0u);
    [[_controller operationForLastPathComponent:@"local.wav"] completeReady:YES];
    [self waitForExpectations:@[localReady] timeout:2];
}

- (void)testForegroundActivityPassesLocalFilesThrough {
    [_localNames addObject:@"local.wav"];
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
    XCTAssertTrue([_controller waitForStartedCount:2]);

    XCTestExpectation *datalessYield = [self expectationWithDescription:@"dataless yielded"];
    __unused AudioFileMaterializationRequestToken *dataless = [self requestName:@"cloud.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultYielded);
        [datalessYield fulfill];
    }];
    [self waitForExpectations:@[datalessYield] timeout:2];
    XCTAssertEqual(_controller.startedOperations.count, 2u);

    [[_controller operationForLastPathComponent:@"local.wav"] completeReady:YES];
    [self waitForExpectations:@[localReady] timeout:2];
}

- (void)testAForegroundRiseDoesNotYieldARunningLocalClaim {
    [_localNames addObject:@"local.wav"];
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

    XCTestExpectation *ready = [self expectationWithDescription:@"local ready"];
    __unused AudioFileMaterializationRequestToken *local = [self requestName:@"local.wav"
            role:VibeAudioFileMaterializationRoleMetadataScan
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [ready fulfill];
    }];
    XCTAssertTrue([_controller waitForStartedCount:1]);
    __unused AudioFileMaterializationRequestToken *playback = [self requestName:@"user-pick.wav"
            role:VibeAudioFileMaterializationRolePlayback
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
    }];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    XCTAssertEqual(_controller.totalCancellationCount, 0u);

    [[_controller operationForLastPathComponent:@"local.wav"] completeReady:YES];
    [self waitForExpectations:@[ready] timeout:2];
}

// The successor never queues behind the sweep: while any foreground transfer
// is live, dataless metadata requests yield at entry — spending no admission
// grace and no budget — so a second prefetch parks into an empty pending
// lane and starts the moment the first settles. This replaces the old
// reserved-slot/eviction arbitration, which the derived rule made
// unrepresentable: metadata can no longer sit pending beside a prefetch.
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
    [self waitForExpectations:@[metadataYielded] timeout:2];
    XCTAssertEqual([_coordinator stateSnapshotForTesting].backgroundPendingCount, 1u);

    [[_controller operationForLastPathComponent:@"blocker.wav"] completeReady:YES];
    [self waitForExpectations:@[blockerDone] timeout:2];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *second = _controller.startedOperations[1];
    XCTAssertEqualObjects(second.url.lastPathComponent, @"next.wav");
    XCTAssertEqual(second.role, VibeAudioFileMaterializationRolePrefetch);
    [second completeReady:YES];
    [self waitForExpectations:@[prefetchDone] timeout:2];
    XCTAssertEqual(_controller.startedOperations.count, 2u);
}

- (void)testLiveConcurrencyRaiseAdmitsAndLoweringOnlyDrains {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 6;
    [self makeCoordinatorWithValues:values];
    NSMutableDictionary<NSString *, XCTestExpectation *> *done = [NSMutableDictionary dictionary];
    NSMutableArray<AudioFileMaterializationRequestToken *> *tokens = [NSMutableArray array];
    for (NSString *name in @[@"a.wav", @"b.wav", @"c.wav", @"d.wav"]) {
        XCTestExpectation *expectation = [self expectationWithDescription:name];
        done[name] = expectation;
        [tokens addObject:[self requestName:name role:VibeAudioFileMaterializationRolePrefetch
                completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
            [expectation fulfill];
        }]];
        if ([name isEqualToString:@"a.wav"]) {
            XCTAssertTrue([_controller waitForStartedCount:1]);
        }
        if ([name isEqualToString:@"c.wav"]) {
            values.maximumBackgroundMaterializations = 2;
            [_coordinator applyConfiguration:[self configurationWithValues:values]];
            XCTAssertTrue([_controller waitForStartedCount:2]);
            values.maximumBackgroundMaterializations = 1;
            [_coordinator applyConfiguration:[self configurationWithValues:values]];
        }
    }
    XCTAssertEqual(_coordinator.currentConfiguration.maximumBackgroundMaterializations, 1u);
    [[_controller operationForLastPathComponent:@"a.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"a.wav"]] timeout:2];
    XCTAssertEqual(_controller.startedOperations.count, 2u,
                   @"lowering must wait for every excess running operation to drain");
    [[_controller operationForLastPathComponent:@"b.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"b.wav"]] timeout:2];
    XCTAssertTrue([_controller waitForStartedCount:3]);
    XCTAssertEqual(_controller.totalCancellationCount, 0u);
    [[_controller operationForLastPathComponent:@"c.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"c.wav"]] timeout:2];
    XCTAssertTrue([_controller waitForStartedCount:4]);
    [[_controller operationForLastPathComponent:@"d.wav"] completeReady:YES];
    [self waitForExpectations:@[done[@"d.wav"]] timeout:2];
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

    _now = 111;
    values.maximumBackgroundMaterializations = 2;
    [_coordinator applyConfiguration:[self configurationWithValues:values]];
    [self waitForExpectations:@[expired] timeout:2];
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

    _now = 111;
    [[_controller operationForLastPathComponent:@"running.wav"] completeReady:YES];
    [self waitForExpectations:@[blockerDone, expired] timeout:2];
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
    [self waitForExpectations:@[expired] timeout:2];
    XCTAssertEqual(_controller.startedOperations.count, 1u);

    [[_controller operationForLastPathComponent:@"running.wav"] completeReady:YES];
    XCTAssertTrue([_controller waitForStartedCount:2]);
    VibeTestMaterializationOperation *same =
            [_controller operationForLastPathComponent:@"same.wav"];
    XCTAssertEqual(same.role, VibeAudioFileMaterializationRoleMetadataScan);
    [same completeReady:YES];
    [self waitForExpectations:@[freshReady] timeout:2];
}

@end
