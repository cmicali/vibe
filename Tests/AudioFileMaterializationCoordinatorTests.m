//
//  AudioFileMaterializationCoordinatorTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "CloudTransferRegistry.h"

@class VibeTestMaterializationController;

@interface VibeTestDatalessProbeController : NSObject
- (BOOL)probeURL:(NSURL *)url;
- (void)setResults:(NSArray<NSNumber *> *)results forName:(NSString *)name;
- (void)gateCall:(NSUInteger)call forName:(NSString *)name;
- (void)releaseCall:(NSUInteger)call forName:(NSString *)name;
- (void)releaseAll;
- (BOOL)waitForCallCount:(NSUInteger)count forName:(NSString *)name;
- (BOOL)waitForIdle;
- (NSUInteger)callCountForName:(NSString *)name;
- (NSUInteger)totalCallCount;
- (NSUInteger)inFlightCount;
- (NSArray<NSString *> *)timedOutGates;
@end

static NSString *VibeProbeCallKey(NSString *name, NSUInteger call) {
    return [NSString stringWithFormat:@"%@:%lu", name, (unsigned long)call];
}

@implementation VibeTestDatalessProbeController {
    NSCondition *_condition;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_resultsByName;
    NSMutableDictionary<NSString *, NSNumber *> *_callsByName;
    NSMutableSet<NSString *> *_gatedCalls;
    NSMutableSet<NSString *> *_releasedCalls;
    NSMutableArray<NSString *> *_timedOutGates;
    NSUInteger _inFlightCount;
    BOOL _releasedAll;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _resultsByName = [NSMutableDictionary dictionary];
        _callsByName = [NSMutableDictionary dictionary];
        _gatedCalls = [NSMutableSet set];
        _releasedCalls = [NSMutableSet set];
        _timedOutGates = [NSMutableArray array];
    }
    return self;
}

// TRAP: if the probe regresses to running on the caller, a gate blocks the
// test method itself and tearDown never releases it. The deadline turns that
// hang into a reported failure.
static const NSTimeInterval kProbeGateTimeout = VIBE_TEST_GATE_TIMEOUT;

- (BOOL)probeURL:(NSURL *)url {
    NSString *name = url.lastPathComponent;
    [_condition lock];
    NSUInteger call = _callsByName[name].unsignedIntegerValue + 1;
    _callsByName[name] = @(call);
    _inFlightCount++;
    NSString *key = VibeProbeCallKey(name, call);
    [_condition broadcast];
    NSDate *gateDeadline = [NSDate dateWithTimeIntervalSinceNow:kProbeGateTimeout];
    while (!_releasedAll && [_gatedCalls containsObject:key]
            && ![_releasedCalls containsObject:key]) {
        if (![_condition waitUntilDate:gateDeadline]) {
            [_timedOutGates addObject:key];
            _releasedAll = YES;
            [_condition broadcast];
            break;
        }
    }
    NSArray<NSNumber *> *results = _resultsByName[name];
    BOOL result = results.count
            ? results[MIN(call - 1, results.count - 1)].boolValue : YES;
    _inFlightCount--;
    [_condition broadcast];
    [_condition unlock];
    return result;
}

- (void)setResults:(NSArray<NSNumber *> *)results forName:(NSString *)name {
    NSParameterAssert(results.count);
    [_condition lock];
    _resultsByName[name] = [results copy];
    [_condition unlock];
}

- (void)gateCall:(NSUInteger)call forName:(NSString *)name {
    [_condition lock];
    [_gatedCalls addObject:VibeProbeCallKey(name, call)];
    [_condition unlock];
}

- (void)releaseCall:(NSUInteger)call forName:(NSString *)name {
    [_condition lock];
    [_releasedCalls addObject:VibeProbeCallKey(name, call)];
    [_condition broadcast];
    [_condition unlock];
}

- (void)releaseAll {
    [_condition lock];
    _releasedAll = YES;
    [_condition broadcast];
    [_condition unlock];
}

- (BOOL)waitForCallCount:(NSUInteger)count forName:(NSString *)name {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    [_condition lock];
    while (_callsByName[name].unsignedIntegerValue < count) {
        if (![_condition waitUntilDate:deadline]) {
            [_condition unlock];
            return NO;
        }
    }
    [_condition unlock];
    return YES;
}

- (BOOL)waitForIdle {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    [_condition lock];
    while (_inFlightCount > 0) {
        if (![_condition waitUntilDate:deadline]) {
            [_condition unlock];
            return NO;
        }
    }
    [_condition unlock];
    return YES;
}

- (NSUInteger)callCountForName:(NSString *)name {
    [_condition lock];
    NSUInteger count = _callsByName[name].unsignedIntegerValue;
    [_condition unlock];
    return count;
}

- (NSUInteger)totalCallCount {
    [_condition lock];
    NSUInteger count = 0;
    for (NSNumber *calls in _callsByName.objectEnumerator) {
        count += calls.unsignedIntegerValue;
    }
    [_condition unlock];
    return count;
}

- (NSUInteger)inFlightCount {
    [_condition lock];
    NSUInteger count = _inFlightCount;
    [_condition unlock];
    return count;
}

- (NSArray<NSString *> *)timedOutGates {
    [_condition lock];
    NSArray<NSString *> *gates = [_timedOutGates copy];
    [_condition unlock];
    return gates;
}

@end

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
- (void)completeWithError:(NSError *)error;
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
    NSError *_finishError;
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

- (BOOL)runOnReadable:(dispatch_block_t)onReadable error:(NSError *__autoreleasing *)error {
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
    NSError *finishError = _finishError;
    [_condition unlock];
    if (!ready && error) {
        *error = finishError
                ?: [NSError errorWithDomain:NSCocoaErrorDomain
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

- (void)completeWithError:(NSError *)error {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = NO;
        _finishError = error;
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
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
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
    VibeTestDatalessProbeController *_probeController;
    AudioFileMaterializationCoordinator *_coordinator;
    dispatch_queue_t _completionQueue;
    NSTimeInterval _now;
}

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
    __weak AudioFileMaterializationCoordinatorTests *weakSelf = self;
    _coordinator = [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
            operationFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [controller operationForURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        return [probeController probeURL:url];
    } clock:^NSTimeInterval{
        AudioFileMaterializationCoordinatorTests *strongSelf = weakSelf;
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
    [self makeCoordinatorWithValues:VibeAudioLoadingProductionConfigurationValues()];

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
