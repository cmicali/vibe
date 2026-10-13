//
//  MaterializationTestFakes.m
//

#import "MaterializationTestFakes.h"

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
