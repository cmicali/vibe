//
//  AudioFileMaterializationCoordinator.m
//  Vibe
//

#import "AudioFileMaterializationCoordinatorInternal.h"

#import "AudioFileOpenRules.h"
#import "CloudFileMaterializer.h"

#import <os/lock.h>

#include <float.h>

NSString * const VibeAudioFileMaterializationErrorDomain =
        @"com.vibe.audio-file-materialization";

typedef NS_ENUM(NSUInteger, VibeMaterializationLane) {
    VibeMaterializationLaneInteractive = 0,
    VibeMaterializationLaneBackground,
};

typedef NS_ENUM(NSUInteger, VibeMaterializationClaimState) {
    VibeMaterializationClaimStatePending = 0,
    VibeMaterializationClaimStateRunning,
};

typedef NS_ENUM(NSUInteger, VibeMaterializationDeliveryState) {
    VibeMaterializationDeliveryWaiting = 0,
    VibeMaterializationDeliveryBegan,
    VibeMaterializationDeliveryDetached,
};

@class VibeAudioFileMaterializationClaim;

@interface AudioFileMaterializationRequestToken ()
- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                path:(NSString *)path
                          identifier:(uint64_t)identifier
                     completionQueue:(dispatch_queue_t)completionQueue
                          registered:(nullable dispatch_block_t)registered
                          completion:(VibeAudioFileMaterializationCompletion)completion;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t identifier;
- (BOOL)isDetached;
- (void)deliverRegistration;
- (void)settleWithResult:(VibeAudioFileMaterializationResult)result
                   error:(nullable NSError *)error
                 elapsed:(NSTimeInterval)elapsed;
- (void)runDelivery;
@end

@interface AudioFileMaterializationHoldToken ()
- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@end

@interface VibeAudioFileMaterializationWaiter : NSObject
@property (nonatomic) uint64_t identifier;
@property (nonatomic) VibeAudioFileMaterializationRole role;
@property (nonatomic) NSTimeInterval submittedAt;
@property (nonatomic, strong) AudioFileMaterializationRequestToken *token;
@end

@implementation VibeAudioFileMaterializationWaiter
@end

@interface VibeAudioFileMaterializationClaim : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, VibeAudioFileMaterializationWaiter *> *waiters;
@property (nonatomic) VibeAudioFileMaterializationRole effectiveRole;
@property (nonatomic) VibeMaterializationLane lane;
@property (nonatomic) VibeMaterializationClaimState state;
@property (nonatomic) uint64_t ordinal;
@property (nonatomic) uint64_t runGeneration;
@property (nonatomic) NSTimeInterval deadline;
@property (nonatomic) BOOL runWasCancelled;
@property (nonatomic, strong, nullable) id<AudioFileMaterializationOperation> operation;
@end

@implementation VibeAudioFileMaterializationClaim
@end

@interface VibeCloudFileMaterializationOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role;
@end

@implementation VibeCloudFileMaterializationOperation {
    NSURL *_url;
    CloudFileMaterializer *_materializer;
    CloudFileMaterializationToken *_token;
}

- (instancetype)initWithURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role {
    self = [super init];
    if (self) {
        _url = url;
        _materializer = [[CloudFileMaterializer alloc] init];
        switch (role) {
            case VibeAudioFileMaterializationRolePlayback:
                _materializer.label = @"playback";
                break;
            case VibeAudioFileMaterializationRolePrefetch:
                _materializer.label = @"prefetch";
                break;
            case VibeAudioFileMaterializationRoleMetadataPriority:
                _materializer.label = @"metadata-priority";
                break;
            case VibeAudioFileMaterializationRoleMetadataScan:
                _materializer.label = @"metadata-scan";
                break;
        }
        _token = [_materializer prepareMaterialization];
    }
    return self;
}

- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    return [_materializer materializeURL:_url token:_token error:error];
}

- (void)cancel {
    [_materializer cancel];
}

@end

@interface AudioFileMaterializationCoordinator ()
- (void)detachRequestToken:(AudioFileMaterializationRequestToken *)token;
- (void)releaseMetadataHold;
@end

@implementation AudioFileMaterializationRequestToken {
    os_unfair_lock _deliveryLock;
    VibeMaterializationDeliveryState _deliveryState;
    dispatch_queue_t _completionQueue;
    dispatch_block_t _registered;
    VibeAudioFileMaterializationCompletion _completion;
    BOOL _deliveryRunnerScheduled;
    BOOL _registrationRequired;
    BOOL _registrationDeliveryBegan;
    BOOL _settled;
    VibeAudioFileMaterializationResult _settledResult;
    NSError *_settledError;
    NSTimeInterval _settledElapsed;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                path:(NSString *)path
                          identifier:(uint64_t)identifier
                     completionQueue:(dispatch_queue_t)completionQueue
                          registered:(dispatch_block_t)registered
                          completion:(VibeAudioFileMaterializationCompletion)completion {
    self = [super init];
    if (self) {
        _deliveryLock = OS_UNFAIR_LOCK_INIT;
        _deliveryState = VibeMaterializationDeliveryWaiting;
        _coordinator = coordinator;
        _path = [path copy];
        _identifier = identifier;
        _completionQueue = completionQueue;
        _registered = [registered copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)cancel {
    dispatch_block_t registeredToRelease = nil;
    VibeAudioFileMaterializationCompletion completionToRelease = nil;
    NSError *errorToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting) {
        _deliveryState = VibeMaterializationDeliveryDetached;
        registeredToRelease = _registered;
        _registered = nil;
        completionToRelease = _completion;
        _completion = nil;
        errorToRelease = _settledError;
        _settledError = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    (void)registeredToRelease;
    (void)completionToRelease;
    (void)errorToRelease;
    [self.coordinator detachRequestToken:self];
}

- (BOOL)isDetached {
    os_unfair_lock_lock(&_deliveryLock);
    BOOL detached = _deliveryState == VibeMaterializationDeliveryDetached;
    os_unfair_lock_unlock(&_deliveryLock);
    return detached;
}

- (void)deliverRegistration {
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting) {
        _registrationRequired = YES;
        if (!_deliveryRunnerScheduled) {
            _deliveryRunnerScheduled = YES;
            shouldSchedule = YES;
        }
    }
    os_unfair_lock_unlock(&_deliveryLock);
    if (shouldSchedule) {
        dispatch_async(_completionQueue, ^{
            [self runDelivery];
        });
    }
}

- (void)settleWithResult:(VibeAudioFileMaterializationResult)result
                   error:(NSError *)error
                 elapsed:(NSTimeInterval)elapsed {
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting && !_settled) {
        _settled = YES;
        _settledResult = result;
        _settledError = error;
        _settledElapsed = elapsed;
        if (result == VibeAudioFileMaterializationResultReady
                || result == VibeAudioFileMaterializationResultFailed) {
            _registrationRequired = YES;
        }
        if (!_deliveryRunnerScheduled) {
            _deliveryRunnerScheduled = YES;
            shouldSchedule = YES;
        }
    }
    os_unfair_lock_unlock(&_deliveryLock);
    if (shouldSchedule) {
        dispatch_async(_completionQueue, ^{
            [self runDelivery];
        });
    }
}

- (void)runDelivery {
    while (YES) {
        dispatch_block_t registered = nil;
        dispatch_block_t registeredToRelease = nil;
        VibeAudioFileMaterializationCompletion completion = nil;
        NSError *error = nil;
        VibeAudioFileMaterializationResult result = VibeAudioFileMaterializationResultFailed;
        NSTimeInterval elapsed = 0;
        BOOL processedRegistration = NO;

        os_unfair_lock_lock(&_deliveryLock);
        if (_deliveryState == VibeMaterializationDeliveryDetached) {
            _deliveryRunnerScheduled = NO;
            os_unfair_lock_unlock(&_deliveryLock);
            return;
        }
        if (_registrationRequired && !_registrationDeliveryBegan) {
            _registrationDeliveryBegan = YES;
            processedRegistration = YES;
            registered = _registered;
            _registered = nil;
        }
        else if (_settled
                && (!_registrationRequired || _registrationDeliveryBegan)) {
            _deliveryState = VibeMaterializationDeliveryBegan;
            _deliveryRunnerScheduled = NO;
            completion = _completion;
            _completion = nil;
            registeredToRelease = _registered;
            _registered = nil;
            result = _settledResult;
            error = _settledError;
            _settledError = nil;
            elapsed = _settledElapsed;
        }
        else {
            _deliveryRunnerScheduled = NO;
            os_unfair_lock_unlock(&_deliveryLock);
            return;
        }
        os_unfair_lock_unlock(&_deliveryLock);

        if (processedRegistration) {
            if (registered) {
                registered();
            }
            continue;
        }
        (void)registeredToRelease;
        if (completion) {
            completion(result, error, elapsed);
        }
        return;
    }
}

@end

@implementation AudioFileMaterializationHoldToken {
    os_unfair_lock _lock;
    BOOL _invalidated;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _coordinator = coordinator;
    }
    return self;
}

- (void)invalidate {
    BOOL shouldRelease = NO;
    os_unfair_lock_lock(&_lock);
    if (!_invalidated) {
        _invalidated = YES;
        shouldRelease = YES;
    }
    os_unfair_lock_unlock(&_lock);
    if (shouldRelease) {
        [self.coordinator releaseMetadataHold];
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

static void *VibeMaterializationStateQueueKey = &VibeMaterializationStateQueueKey;

@implementation AudioFileMaterializationCoordinator {
    dispatch_queue_t _stateQueue;
    dispatch_queue_t _interactiveWorkerQueue;
    dispatch_queue_t _backgroundWorkerQueue;
    dispatch_source_t _pendingTimer;
    NSMutableDictionary<NSString *, VibeAudioFileMaterializationClaim *> *_claims;
    NSMutableArray<VibeAudioFileMaterializationClaim *> *_interactivePending;
    NSMutableArray<VibeAudioFileMaterializationClaim *> *_backgroundPending;
    NSUInteger _interactiveRunningCount;
    NSUInteger _backgroundRunningCount;
    NSUInteger _metadataHoldCount;
    uint64_t _nextRequestIdentifier;
    uint64_t _nextClaimOrdinal;
    AudioLoadingConfiguration *_configuration;
    VibeAudioFileMaterializationOperationFactory _operationFactory;
    VibeAudioFileMaterializationClock _clock;
}

+ (instancetype)sharedCoordinator {
    static AudioFileMaterializationCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

- (instancetype)init {
    AudioLoadingConfiguration *configuration = [AudioLoadingConfiguration productionConfiguration];
    return [self initWithConfiguration:configuration
                      operationFactory:^id<AudioFileMaterializationOperation>(
                              NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[VibeCloudFileMaterializationOperation alloc] initWithURL:url role:role];
    } clock:^NSTimeInterval{
        return NSProcessInfo.processInfo.systemUptime;
    }];
}

- (instancetype)initWithConfiguration:(AudioLoadingConfiguration *)configuration
                      operationFactory:(VibeAudioFileMaterializationOperationFactory)operationFactory
                                  clock:(VibeAudioFileMaterializationClock)clock {
    NSParameterAssert(configuration);
    NSParameterAssert(operationFactory);
    NSParameterAssert(clock);
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _operationFactory = [operationFactory copy];
        _clock = [clock copy];
        _claims = [NSMutableDictionary dictionary];
        _interactivePending = [NSMutableArray array];
        _backgroundPending = [NSMutableArray array];
        _stateQueue = dispatch_queue_create("com.vibe.materialization.state", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_stateQueue, VibeMaterializationStateQueueKey,
                                    (__bridge void *)self, NULL);
        dispatch_queue_attr_t interactiveAttributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        _interactiveWorkerQueue = dispatch_queue_create(
                "com.vibe.materialization.interactive", interactiveAttributes);
        dispatch_queue_attr_t backgroundAttributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0);
        _backgroundWorkerQueue = dispatch_queue_create(
                "com.vibe.materialization.background", backgroundAttributes);
        _pendingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _stateQueue);
        dispatch_source_set_timer(_pendingTimer, DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER, 0);
        __weak AudioFileMaterializationCoordinator *weakSelf = self;
        dispatch_source_set_event_handler(_pendingTimer, ^{
            AudioFileMaterializationCoordinator *strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf expirePendingClaimsAtTime:strongSelf->_clock() drain:YES];
            }
        });
        dispatch_resume(_pendingTimer);
    }
    return self;
}

- (void)dealloc {
    dispatch_source_cancel(_pendingTimer);
}

- (void)performStateSynchronously:(dispatch_block_t)block {
    if (dispatch_get_specific(VibeMaterializationStateQueueKey) == (__bridge void *)self) {
        block();
    }
    else {
        dispatch_sync(_stateQueue, block);
    }
}

- (AudioLoadingConfiguration *)currentConfiguration {
    __block AudioLoadingConfiguration *configuration;
    [self performStateSynchronously:^{
        configuration = self->_configuration;
    }];
    return configuration;
}

- (void)applyConfiguration:(AudioLoadingConfiguration *)configuration {
    NSParameterAssert(configuration);
    [self performStateSynchronously:^{
        [self expirePendingClaimsAtTime:self->_clock() drain:NO];
        self->_configuration = [configuration copy];
        [self drainPendingClaims];
        [self reschedulePendingTimer];
    }];
}

static BOOL VibeMaterializationRoleIsMetadata(VibeAudioFileMaterializationRole role) {
    return role == VibeAudioFileMaterializationRoleMetadataPriority
            || role == VibeAudioFileMaterializationRoleMetadataScan;
}

static VibeMaterializationLane VibeLaneForRole(VibeAudioFileMaterializationRole role) {
    return role == VibeAudioFileMaterializationRolePlayback
            ? VibeMaterializationLaneInteractive : VibeMaterializationLaneBackground;
}

- (uint64_t)nextRequestIdentifier {
    _nextRequestIdentifier++;
    if (_nextRequestIdentifier == 0) {
        _nextRequestIdentifier++;
    }
    return _nextRequestIdentifier;
}

- (VibeAudioFileMaterializationRole)effectiveRoleForClaim:(VibeAudioFileMaterializationClaim *)claim {
    VibeAudioFileMaterializationRole role = VibeAudioFileMaterializationRoleMetadataScan;
    for (VibeAudioFileMaterializationWaiter *waiter in claim.waiters.objectEnumerator) {
        role = MIN(role, waiter.role);
    }
    return role;
}

- (BOOL)claimHasNonMetadataWaiter:(VibeAudioFileMaterializationClaim *)claim {
    for (VibeAudioFileMaterializationWaiter *waiter in claim.waiters.objectEnumerator) {
        if (!VibeMaterializationRoleIsMetadata(waiter.role)) {
            return YES;
        }
    }
    return NO;
}

- (NSError *)admissionError:(NSString *)description {
    return [NSError errorWithDomain:VibeAudioFileMaterializationErrorDomain
                               code:VibeAudioFileMaterializationErrorAdmissionExhausted
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (NSError *)missingFailureError {
    return [NSError errorWithDomain:VibeAudioFileMaterializationErrorDomain
                               code:VibeAudioFileMaterializationErrorFailed
                           userInfo:@{NSLocalizedDescriptionKey:
                                          @"Audio file materialization failed"}];
}

- (AudioFileMaterializationRequestToken *)materializeURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role
                                         completionQueue:(dispatch_queue_t)completionQueue
                                              registered:(dispatch_block_t)registered
                                              completion:(VibeAudioFileMaterializationCompletion)completion {
    NSParameterAssert(url);
    NSParameterAssert(completionQueue);
    NSParameterAssert(completion);
    NSString *path = VibeStandardizedAudioOpenPath(url);
    __block AudioFileMaterializationRequestToken *token;
    [self performStateSynchronously:^{
        uint64_t identifier = [self nextRequestIdentifier];
        token = [[AudioFileMaterializationRequestToken alloc]
                initWithCoordinator:self path:path identifier:identifier
                completionQueue:completionQueue registered:registered completion:completion];
        [self expirePendingClaimsAtTime:self->_clock() drain:NO];
        VibeAudioFileMaterializationClaim *claim = self->_claims[path];
        BOOL heldMetadata = VibeMaterializationRoleIsMetadata(role)
                && self->_metadataHoldCount > 0;
        if (heldMetadata && (!claim || ![self claimHasNonMetadataWaiter:claim])) {
            [token settleWithResult:VibeAudioFileMaterializationResultYielded
                             error:nil elapsed:0];
            return;
        }

        VibeAudioFileMaterializationWaiter *waiter =
                [[VibeAudioFileMaterializationWaiter alloc] init];
        waiter.identifier = identifier;
        waiter.role = role;
        waiter.submittedAt = self->_clock();
        waiter.token = token;

        if (claim) {
            VibeAudioFileMaterializationRole oldRole = claim.effectiveRole;
            claim.waiters[@(identifier)] = waiter;
            claim.effectiveRole = [self effectiveRoleForClaim:claim];
            if (claim.state == VibeMaterializationClaimStatePending
                    && claim.effectiveRole != oldRole) {
                [self readmitPendingClaim:claim];
            }
            [token deliverRegistration];
            [self drainPendingClaims];
            [self reschedulePendingTimer];
            return;
        }

        claim = [[VibeAudioFileMaterializationClaim alloc] init];
        claim.path = path;
        claim.url = url;
        claim.waiters = [NSMutableDictionary dictionaryWithObject:waiter
                                                            forKey:@(identifier)];
        claim.effectiveRole = role;
        claim.ordinal = ++self->_nextClaimOrdinal;
        self->_claims[path] = claim;
        if (![self admitClaim:claim preserveExistingAdmission:NO]) {
            [self->_claims removeObjectForKey:path];
            NSError *error = [self admissionError:
                    @"Audio materialization capacity has no pending slot"];
            [token settleWithResult:VibeAudioFileMaterializationResultAdmissionExhausted
                             error:error elapsed:0];
            [self reschedulePendingTimer];
            return;
        }
        [token deliverRegistration];
        [self reschedulePendingTimer];
    }];
    return token;
}

- (BOOL)admitClaim:(VibeAudioFileMaterializationClaim *)claim
        preserveExistingAdmission:(BOOL)preserveExistingAdmission {
    VibeMaterializationLane lane = VibeLaneForRole(claim.effectiveRole);
    claim.lane = lane;
    NSUInteger running = lane == VibeMaterializationLaneInteractive
            ? _interactiveRunningCount : _backgroundRunningCount;
    NSUInteger maximumRunning = lane == VibeMaterializationLaneInteractive
            ? _configuration.maximumInteractiveMaterializations
            : _configuration.maximumBackgroundMaterializations;
    if (running < maximumRunning) {
        [self startClaim:claim];
        return YES;
    }

    NSMutableArray<VibeAudioFileMaterializationClaim *> *pending =
            lane == VibeMaterializationLaneInteractive
                    ? _interactivePending : _backgroundPending;
    NSUInteger maximumPending = lane == VibeMaterializationLaneInteractive
            ? _configuration.maximumInteractivePendingMaterializations
            : _configuration.maximumBackgroundPendingMaterializations;

    if (lane == VibeMaterializationLaneBackground
            && claim.effectiveRole == VibeAudioFileMaterializationRolePrefetch
            && pending.count >= maximumPending) {
        VibeAudioFileMaterializationClaim *evicted = nil;
        while (pending.count >= maximumPending
                && (evicted = [self worstPendingMetadataClaim])) {
            [self yieldClaim:evicted];
        }
    }

    BOOL mayPark = preserveExistingAdmission;
    if (!mayPark && lane == VibeMaterializationLaneBackground
            && VibeMaterializationRoleIsMetadata(claim.effectiveRole)) {
        BOOL hasPendingPrefetch = NO;
        for (VibeAudioFileMaterializationClaim *candidate in pending) {
            if (candidate.effectiveRole == VibeAudioFileMaterializationRolePrefetch) {
                hasPendingPrefetch = YES;
                break;
            }
        }
        NSUInteger reserved = hasPendingPrefetch ? 0 : 1;
        NSUInteger metadataLimit = maximumPending > reserved ? maximumPending - reserved : 0;
        mayPark = pending.count < metadataLimit;
    }
    else if (!mayPark) {
        mayPark = pending.count < maximumPending;
    }
    if (!mayPark) {
        return NO;
    }

    claim.state = VibeMaterializationClaimStatePending;
    NSTimeInterval grace = lane == VibeMaterializationLaneInteractive
            ? _configuration.interactiveAdmissionGrace
            : _configuration.backgroundAdmissionGrace;
    claim.deadline = _clock() + grace;
    [pending addObject:claim];
    return YES;
}

- (VibeAudioFileMaterializationClaim *)worstPendingMetadataClaim {
    VibeAudioFileMaterializationClaim *worst = nil;
    for (VibeAudioFileMaterializationClaim *claim in _backgroundPending) {
        if (!VibeMaterializationRoleIsMetadata(claim.effectiveRole)) {
            continue;
        }
        if (!worst || claim.effectiveRole > worst.effectiveRole
                || (claim.effectiveRole == worst.effectiveRole
                    && claim.ordinal > worst.ordinal)) {
            worst = claim;
        }
    }
    return worst;
}

- (void)removePendingClaim:(VibeAudioFileMaterializationClaim *)claim {
    [_interactivePending removeObjectIdenticalTo:claim];
    [_backgroundPending removeObjectIdenticalTo:claim];
}

- (void)readmitPendingClaim:(VibeAudioFileMaterializationClaim *)claim {
    [self removePendingClaim:claim];
    [self admitClaim:claim preserveExistingAdmission:YES];
}

- (void)startClaim:(VibeAudioFileMaterializationClaim *)claim {
    claim.state = VibeMaterializationClaimStateRunning;
    claim.lane = VibeLaneForRole(claim.effectiveRole);
    claim.runGeneration++;
    claim.runWasCancelled = NO;
    uint64_t runGeneration = claim.runGeneration;
    if (claim.lane == VibeMaterializationLaneInteractive) {
        _interactiveRunningCount++;
    }
    else {
        _backgroundRunningCount++;
    }

    id<AudioFileMaterializationOperation> operation =
            _operationFactory(claim.url, claim.effectiveRole);
    claim.operation = operation;
    if (!operation) {
        [self finishClaim:claim runGeneration:runGeneration ready:NO
                    error:[self missingFailureError]];
        return;
    }

    dispatch_queue_t workerQueue = claim.lane == VibeMaterializationLaneInteractive
            ? _interactiveWorkerQueue : _backgroundWorkerQueue;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    dispatch_async(workerQueue, ^{
        NSError *error = nil;
        BOOL ready = [operation runWithError:&error];
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf->_stateQueue, ^{
            [strongSelf finishClaim:claim runGeneration:runGeneration ready:ready error:error];
        });
    });
}

- (void)finishClaim:(VibeAudioFileMaterializationClaim *)claim
       runGeneration:(uint64_t)runGeneration
                ready:(BOOL)ready
                error:(NSError *)error {
    VibeAudioFileMaterializationClaim *current = _claims[claim.path];
    if (current != claim || claim.runGeneration != runGeneration
            || claim.state != VibeMaterializationClaimStateRunning) {
        return;
    }
    if (claim.lane == VibeMaterializationLaneInteractive) {
        if (_interactiveRunningCount > 0) _interactiveRunningCount--;
    }
    else {
        if (_backgroundRunningCount > 0) _backgroundRunningCount--;
    }
    claim.operation = nil;

    if (claim.runWasCancelled) {
        claim.runWasCancelled = NO;
        if (claim.waiters.count) {
            if (![self admitClaim:claim preserveExistingAdmission:YES]) {
                [self settleClaim:claim
                           result:VibeAudioFileMaterializationResultAdmissionExhausted
                            error:[self admissionError:
                                    @"Audio materialization could not be readmitted"]];
            }
        }
        else {
            [_claims removeObjectForKey:claim.path];
        }
    }
    else {
        [self settleClaim:claim
                   result:ready ? VibeAudioFileMaterializationResultReady
                                : VibeAudioFileMaterializationResultFailed
                    error:ready ? nil : (error ?: [self missingFailureError])];
    }
    [self drainPendingClaims];
    [self reschedulePendingTimer];
}

- (void)settleClaim:(VibeAudioFileMaterializationClaim *)claim
             result:(VibeAudioFileMaterializationResult)result
              error:(NSError *)error {
    [self removePendingClaim:claim];
    if (_claims[claim.path] == claim) {
        [_claims removeObjectForKey:claim.path];
    }
    NSArray<VibeAudioFileMaterializationWaiter *> *waiters = claim.waiters.allValues;
    [claim.waiters removeAllObjects];
    NSTimeInterval now = _clock();
    for (VibeAudioFileMaterializationWaiter *waiter in waiters) {
        [waiter.token settleWithResult:result error:error
                               elapsed:MAX(0, now - waiter.submittedAt)];
    }
}

- (void)yieldClaim:(VibeAudioFileMaterializationClaim *)claim {
    NSArray<VibeAudioFileMaterializationWaiter *> *waiters = claim.waiters.allValues;
    [claim.waiters removeAllObjects];
    NSTimeInterval now = _clock();
    for (VibeAudioFileMaterializationWaiter *waiter in waiters) {
        [waiter.token settleWithResult:VibeAudioFileMaterializationResultYielded
                                 error:nil elapsed:MAX(0, now - waiter.submittedAt)];
    }
    if (claim.state == VibeMaterializationClaimStatePending) {
        [self removePendingClaim:claim];
        if (_claims[claim.path] == claim) {
            [_claims removeObjectForKey:claim.path];
        }
    }
    else {
        claim.runWasCancelled = YES;
        [claim.operation cancel];
    }
}

- (NSUInteger)bestPendingIndexInArray:(NSArray<VibeAudioFileMaterializationClaim *> *)pending {
    NSUInteger best = NSNotFound;
    for (NSUInteger index = 0; index < pending.count; index++) {
        VibeAudioFileMaterializationClaim *candidate = pending[index];
        if (_metadataHoldCount > 0
                && VibeMaterializationRoleIsMetadata(candidate.effectiveRole)) {
            continue;
        }
        if (best == NSNotFound) {
            best = index;
            continue;
        }
        VibeAudioFileMaterializationClaim *current = pending[best];
        if (candidate.effectiveRole < current.effectiveRole
                || (candidate.effectiveRole == current.effectiveRole
                    && candidate.ordinal < current.ordinal)) {
            best = index;
        }
    }
    return best;
}

- (void)drainPendingClaims {
    [self expirePendingClaimsAtTime:_clock() drain:NO];
    while (_interactiveRunningCount < _configuration.maximumInteractiveMaterializations) {
        NSUInteger index = [self bestPendingIndexInArray:_interactivePending];
        if (index == NSNotFound) break;
        VibeAudioFileMaterializationClaim *claim = _interactivePending[index];
        [_interactivePending removeObjectAtIndex:index];
        [self startClaim:claim];
    }
    while (_backgroundRunningCount < _configuration.maximumBackgroundMaterializations) {
        NSUInteger index = [self bestPendingIndexInArray:_backgroundPending];
        if (index == NSNotFound) break;
        VibeAudioFileMaterializationClaim *claim = _backgroundPending[index];
        [_backgroundPending removeObjectAtIndex:index];
        [self startClaim:claim];
    }
}

- (void)detachRequestToken:(AudioFileMaterializationRequestToken *)token {
    if (!token) return;
    dispatch_async(_stateQueue, ^{
        VibeAudioFileMaterializationClaim *claim = self->_claims[token.path];
        VibeAudioFileMaterializationWaiter *waiter = claim.waiters[@(token.identifier)];
        if (!claim || waiter.token != token) {
            return;
        }
        VibeAudioFileMaterializationRole oldRole = claim.effectiveRole;
        [claim.waiters removeObjectForKey:@(token.identifier)];
        if (!claim.waiters.count) {
            if (claim.state == VibeMaterializationClaimStatePending) {
                [self removePendingClaim:claim];
                [self->_claims removeObjectForKey:claim.path];
            }
            else {
                claim.runWasCancelled = YES;
                [claim.operation cancel];
            }
        }
        else {
            claim.effectiveRole = [self effectiveRoleForClaim:claim];
            if (self->_metadataHoldCount > 0 && ![self claimHasNonMetadataWaiter:claim]) {
                [self yieldClaim:claim];
            }
            else if (claim.state == VibeMaterializationClaimStatePending
                    && claim.effectiveRole != oldRole) {
                [self readmitPendingClaim:claim];
            }
        }
        [self drainPendingClaims];
        [self reschedulePendingTimer];
    });
}

- (AudioFileMaterializationHoldToken *)acquireMetadataHold {
    [self performStateSynchronously:^{
        self->_metadataHoldCount++;
        if (self->_metadataHoldCount == 1) {
            NSArray<VibeAudioFileMaterializationClaim *> *claims =
                    self->_claims.allValues;
            for (VibeAudioFileMaterializationClaim *claim in claims) {
                if (claim.waiters.count && ![self claimHasNonMetadataWaiter:claim]) {
                    [self yieldClaim:claim];
                }
            }
            [self drainPendingClaims];
            [self reschedulePendingTimer];
        }
    }];
    return [[AudioFileMaterializationHoldToken alloc] initWithCoordinator:self];
}

- (void)releaseMetadataHold {
    [self performStateSynchronously:^{
        if (self->_metadataHoldCount == 0) {
            return;
        }
        self->_metadataHoldCount--;
        if (self->_metadataHoldCount == 0) {
            [self drainPendingClaims];
            [self reschedulePendingTimer];
        }
    }];
}

- (void)expirePendingClaimsAtTime:(NSTimeInterval)now drain:(BOOL)drain {
    NSArray<NSArray<VibeAudioFileMaterializationClaim *> *> *lists =
            @[[ _interactivePending copy ], [ _backgroundPending copy ]];
    for (NSArray<VibeAudioFileMaterializationClaim *> *list in lists) {
        for (VibeAudioFileMaterializationClaim *claim in list) {
            if (claim.deadline > now) continue;
            [self settleClaim:claim
                       result:VibeAudioFileMaterializationResultAdmissionExhausted
                        error:[self admissionError:
                                @"Audio materialization stayed pending past its admission grace"]];
        }
    }
    if (drain) {
        [self drainPendingClaims];
        [self reschedulePendingTimer];
    }
}

- (void)reschedulePendingTimer {
    NSTimeInterval earliest = DBL_MAX;
    for (VibeAudioFileMaterializationClaim *claim in _interactivePending) {
        earliest = MIN(earliest, claim.deadline);
    }
    for (VibeAudioFileMaterializationClaim *claim in _backgroundPending) {
        earliest = MIN(earliest, claim.deadline);
    }
    if (earliest == DBL_MAX) {
        dispatch_source_set_timer(_pendingTimer, DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER, 0);
        return;
    }
    NSTimeInterval delay = MAX(0, earliest - _clock());
    dispatch_source_set_timer(_pendingTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
}

- (VibeAudioFileMaterializationCoordinatorSnapshot)stateSnapshotForTesting {
    __block VibeAudioFileMaterializationCoordinatorSnapshot snapshot;
    [self performStateSynchronously:^{
        snapshot.claimCount = self->_claims.count;
        snapshot.waiterCount = 0;
        for (VibeAudioFileMaterializationClaim *claim in self->_claims.objectEnumerator) {
            snapshot.waiterCount += claim.waiters.count;
        }
        snapshot.interactiveRunningCount = self->_interactiveRunningCount;
        snapshot.backgroundRunningCount = self->_backgroundRunningCount;
        snapshot.interactivePendingCount = self->_interactivePending.count;
        snapshot.backgroundPendingCount = self->_backgroundPending.count;
        snapshot.metadataHoldCount = self->_metadataHoldCount;
    }];
    return snapshot;
}

- (void)expirePendingClaimsForTesting {
    [self performStateSynchronously:^{
        [self expirePendingClaimsAtTime:self->_clock() drain:YES];
    }];
}

@end
