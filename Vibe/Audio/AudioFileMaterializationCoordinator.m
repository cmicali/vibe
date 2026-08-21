//
//  AudioFileMaterializationCoordinator.m
//  Vibe
//

#import "AudioFileMaterializationCoordinatorInternal.h"

#import "AudioFileOpenRules.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistryInternal.h"
#import "NSURL+AudioOpen.h"
#import "NSURLUtil.h"

#import <AVFoundation/AVFoundation.h>

#import <os/lock.h>

#include <float.h>
#include <stdatomic.h>

NSString * const VibeAudioFileMaterializationErrorDomain =
        @"com.vibe.audio-file-materialization";
NSString * const VibeAudioFileOpenErrorDomain = @"com.vibe.audio-file-open";

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
                          completion:(VibeAudioFileMaterializationCompletion)completion;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t identifier;
- (BOOL)isDetached;
- (void)settleWithResult:(VibeAudioFileMaterializationResult)result
                   error:(nullable NSError *)error
                 elapsed:(NSTimeInterval)elapsed;
- (void)runDelivery;
@end

@interface AudioFileOpenToken ()
- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                  key:(NSString *)key
                      completionQueue:(dispatch_queue_t)completionQueue
                           completion:(VibeAudioFileOpenCompletion)completion;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
- (nullable VibeAudioFileOpenCompletion)takeCompletionForDelivery;
- (BOOL)deliveryStillWaiting;
@end

// Stage 2: one purpose's AVAudioFile open for one standardized path, riding
// the path's transfer claim. Lean on purpose: the run IS the old open
// coordinator's claim, on the same state queue as the transfer it follows.
@interface VibeAudioHandleRun : NSObject
@property (nonatomic, copy) NSString *key;         // "purpose:path"
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) VibeAudioFileOpenPurpose purpose;
@property (nonatomic, strong, nullable) AudioFileOpenToken *waiter;
@property (nonatomic, strong, nullable) AudioFileMaterializationRequestToken *materializationToken;
@property (nonatomic) uint64_t runGeneration;
@property (nonatomic) BOOL runWasCancelled;
@property (nonatomic) CFAbsoluteTime submittedAt;
@end

@implementation VibeAudioHandleRun
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
@property (nonatomic) NSUInteger inheritedCancelRestarts;
// Whether this run's start was published to CloudTransferRegistry — the probe
// computed once at startClaim:, stashed so a run that starts and finishes
// cannot disagree about whether it was a transfer.
@property (nonatomic) BOOL publishedTransfer;
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
- (void)detachOpenToken:(AudioFileOpenToken *)token;
@end

@implementation AudioFileMaterializationRequestToken {
    os_unfair_lock _deliveryLock;
    VibeMaterializationDeliveryState _deliveryState;
    dispatch_queue_t _completionQueue;
    VibeAudioFileMaterializationCompletion _completion;
    BOOL _deliveryRunnerScheduled;
    BOOL _settled;
    VibeAudioFileMaterializationResult _settledResult;
    NSError *_settledError;
    NSTimeInterval _settledElapsed;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                path:(NSString *)path
                          identifier:(uint64_t)identifier
                     completionQueue:(dispatch_queue_t)completionQueue
                          completion:(VibeAudioFileMaterializationCompletion)completion {
    self = [super init];
    if (self) {
        _deliveryLock = OS_UNFAIR_LOCK_INIT;
        _deliveryState = VibeMaterializationDeliveryWaiting;
        _coordinator = coordinator;
        _path = [path copy];
        _identifier = identifier;
        _completionQueue = completionQueue;
        _completion = [completion copy];
    }
    return self;
}

- (void)cancel {
    VibeAudioFileMaterializationCompletion completionToRelease = nil;
    NSError *errorToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting) {
        _deliveryState = VibeMaterializationDeliveryDetached;
        completionToRelease = _completion;
        _completion = nil;
        errorToRelease = _settledError;
        _settledError = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
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

// Single-shot: a settle schedules exactly one delivery, and a cancel landing
// before it runs suppresses the queued completion. The two-phase loop this
// once was existed only to order the registered: callback ahead of the
// completion; the registration concept left with the acknowledgement
// machinery.
- (void)runDelivery {
    VibeAudioFileMaterializationCompletion completion = nil;
    NSError *error = nil;
    VibeAudioFileMaterializationResult result = VibeAudioFileMaterializationResultFailed;
    NSTimeInterval elapsed = 0;
    os_unfair_lock_lock(&_deliveryLock);
    _deliveryRunnerScheduled = NO;
    if (_deliveryState == VibeMaterializationDeliveryWaiting && _settled) {
        _deliveryState = VibeMaterializationDeliveryBegan;
        completion = _completion;
        _completion = nil;
        result = _settledResult;
        error = _settledError;
        _settledError = nil;
        elapsed = _settledElapsed;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    if (completion) {
        completion(result, error, elapsed);
    }
}

@end

@implementation AudioFileOpenToken {
    os_unfair_lock _deliveryLock;
    VibeAudioFileOpenDeliveryState _deliveryState;
    VibeAudioFileOpenCompletion _completion;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                  key:(NSString *)key
                      completionQueue:(dispatch_queue_t)completionQueue
                           completion:(VibeAudioFileOpenCompletion)completion {
    self = [super init];
    if (self) {
        _deliveryLock = OS_UNFAIR_LOCK_INIT;
        _deliveryState = VibeAudioFileOpenDeliveryWaiting;
        _coordinator = coordinator;
        _key = [key copy];
        _completionQueue = completionQueue;
        _completion = [completion copy];
    }
    return self;
}

- (void)cancel {
    VibeAudioFileOpenCompletion completionToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (VibeAudioFileOpenDetachDelivery(&_deliveryState)) {
        completionToRelease = _completion;
        _completion = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    (void)completionToRelease;
    [self.coordinator detachOpenToken:self];
}

// Whether a cancel has not yet detached this token. openURL's state-queue
// block reads it so a token cancelled between creation and installation never
// installs a run.
- (BOOL)deliveryStillWaiting {
    os_unfair_lock_lock(&_deliveryLock);
    BOOL waiting = _deliveryState == VibeAudioFileOpenDeliveryWaiting;
    os_unfair_lock_unlock(&_deliveryLock);
    return waiting;
}

- (VibeAudioFileOpenCompletion)takeCompletionForDelivery {
    VibeAudioFileOpenCompletion completion = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (VibeAudioFileOpenBeginDelivery(&_deliveryState)) {
        completion = _completion;
        _completion = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    return completion;
}

@end

static void *VibeMaterializationStateQueueKey = &VibeMaterializationStateQueueKey;

@implementation AudioFileMaterializationCoordinator {
    dispatch_queue_t _stateQueue;
    dispatch_queue_t _interactiveWorkerQueue;
    dispatch_queue_t _backgroundWorkerQueue;
    dispatch_source_t _pendingTimer;
    NSMutableDictionary<NSString *, VibeAudioFileMaterializationClaim *> *_claims;
    // Stage 2, keyed "purpose:path". A run outlives its transfer claim: the
    // claim leaves _claims at settlement while the AVAudioFile open it fed is
    // still returning, and the transfer's lane slot rides along in
    // _carriedSlotLanes until the path's last run finishes.
    NSMutableDictionary<NSString *, VibeAudioHandleRun *> *_handleRuns;
    NSMutableDictionary<NSString *, NSNumber *> *_carriedSlotLanes;
    NSMutableArray<VibeAudioFileMaterializationClaim *> *_interactivePending;
    NSMutableArray<VibeAudioFileMaterializationClaim *> *_backgroundPending;
    NSUInteger _interactiveRunningCount;
    NSUInteger _backgroundRunningCount;
    uint64_t _nextRequestIdentifier;
    uint64_t _nextClaimOrdinal;
    AudioLoadingConfiguration *_configuration;
    VibeAudioFileMaterializationOperationFactory _operationFactory;
    VibeAudioFileMaterializationDatalessProbe _datalessProbe;
    VibeAudioFileMaterializationClock _clock;
    VibeAudioFileOpener _fileOpener;
    // Atomic because the health probe reads them off the state queue. It must
    // never take that queue: admission runs the dataless probe inside it, which
    // is a stat that can block for a long time on a dead mount — the very
    // condition the probe exists to report. Written only on the state queue, so
    // relaxed ordering on the write side would do; the default is not hot.
    _Atomic uint64_t _handleOpensStarted;
    _Atomic uint64_t _handleOpensCompleted;
    uint64_t _requestsReady;
    uint64_t _requestsFailed;
    uint64_t _requestsYielded;
    uint64_t _requestsAdmissionExhausted;
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
    } datalessProbe:^BOOL(NSURL *url) {
        return [NSURLUtil isDatalessFile:url];
    } clock:^NSTimeInterval{
        return NSProcessInfo.processInfo.systemUptime;
    }];
}

- (instancetype)initWithFileOpener:(VibeAudioFileOpener)fileOpener {
    AudioLoadingConfiguration *configuration = [AudioLoadingConfiguration productionConfiguration];
    return [self initWithConfiguration:configuration
                      operationFactory:^id<AudioFileMaterializationOperation>(
                              NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[VibeCloudFileMaterializationOperation alloc] initWithURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        return [NSURLUtil isDatalessFile:url];
    } clock:^NSTimeInterval{
        return NSProcessInfo.processInfo.systemUptime;
    } fileOpener:fileOpener];
}

- (instancetype)initWithConfiguration:(AudioLoadingConfiguration *)configuration
                      operationFactory:(VibeAudioFileMaterializationOperationFactory)operationFactory
                          datalessProbe:(VibeAudioFileMaterializationDatalessProbe)datalessProbe
                                  clock:(VibeAudioFileMaterializationClock)clock {
    return [self initWithConfiguration:configuration
                      operationFactory:operationFactory
                          datalessProbe:datalessProbe
                                  clock:clock
                            fileOpener:^AVAudioFile *(NSURL *url, NSError **error) {
        return url.failsAudioOpenPreflight
                ? nil : [[AVAudioFile alloc] initForReading:url error:error];
    }];
}

- (instancetype)initWithConfiguration:(AudioLoadingConfiguration *)configuration
                      operationFactory:(VibeAudioFileMaterializationOperationFactory)operationFactory
                          datalessProbe:(VibeAudioFileMaterializationDatalessProbe)datalessProbe
                                  clock:(VibeAudioFileMaterializationClock)clock
                            fileOpener:(VibeAudioFileOpener)fileOpener {
    NSParameterAssert(configuration);
    NSParameterAssert(fileOpener);
    NSParameterAssert(operationFactory);
    NSParameterAssert(datalessProbe);
    NSParameterAssert(clock);
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _operationFactory = [operationFactory copy];
        _datalessProbe = [datalessProbe copy];
        _clock = [clock copy];
        _fileOpener = [fileOpener copy];
        _claims = [NSMutableDictionary dictionary];
        _handleRuns = [NSMutableDictionary dictionary];
        _carriedSlotLanes = [NSMutableDictionary dictionary];
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

// The C1 rule's single source, derived from the claim table rather than
// counted: any live claim with a playback or prefetch waiter means the user
// (or their successor) is waiting on a transfer, and background metadata
// work must not compete for the provider. Claims leave the table exactly at
// settlement, so there is no release edge to deliver — the same
// drainPendingClaims every settlement path already runs is the reopening.
// O(claims), and the table is small by construction (running + pending
// bounds).
- (BOOL)foregroundTransferActiveLocked {
    for (VibeAudioFileMaterializationClaim *claim in _claims.objectEnumerator) {
        if (claim.waiters.count && [self claimHasNonMetadataWaiter:claim]) {
            return YES;
        }
    }
    return NO;
}

// Lock-free by contract: see the ivar comment. The two counters are read
// separately, so a concurrent open that starts between them reads as not yet
// started — which understates, never overstates, the number of stranded calls.
// The stage-2 injection seam. Tests get theirs at init; the debug channel
// needs to wrap the live shared coordinator's, which is what this is for.
- (VibeAudioFileOpener)fileOpener {
    __block VibeAudioFileOpener opener;
    [self performStateSynchronously:^{
        opener = self->_fileOpener;
    }];
    return opener;
}

- (void)setFileOpener:(VibeAudioFileOpener)fileOpener {
    NSParameterAssert(fileOpener);
    [self performStateSynchronously:^{
        self->_fileOpener = [fileOpener copy];
    }];
}

- (uint64_t)handleOpensInFlight {
    uint64_t completed = atomic_load(&_handleOpensCompleted);
    uint64_t started = atomic_load(&_handleOpensStarted);
    return started > completed ? started - completed : 0;
}

- (BOOL)isForegroundTransferActive {
    __block BOOL active;
    [self performStateSynchronously:^{
        active = [self foregroundTransferActiveLocked];
    }];
    return active;
}

// The rising edge: the first foreground waiter preempts every metadata-only
// dataless claim, running ones included — the sweep's in-flight download is
// cancelled, not waited out (C6). The path the foreground request is about
// to join is exempt: one transfer per path is the load-bearing rule (A2),
// and yielding the claim it is joining would cancel the very download it
// came for. Local claims pass because they hold no transfer the rule
// protects.
- (void)preemptMetadataClaimsForForegroundRiseExcludingPath:(NSString *)joinedPath {
    NSArray<VibeAudioFileMaterializationClaim *> *claims = _claims.allValues;
    for (VibeAudioFileMaterializationClaim *claim in claims) {
        if ([claim.path isEqualToString:joinedPath]) {
            continue;
        }
        if (claim.waiters.count && ![self claimHasNonMetadataWaiter:claim]
                && _datalessProbe(claim.url)) {
            [self yieldClaim:claim];
        }
    }
}

// The materializer's one spelling of cancellation (System/CLAUDE.md), which is
// also what NSFileCoordinator's own -cancel returns.
static BOOL VibeMaterializationErrorIsCancellation(NSError *error) {
    return [error.domain isEqualToString:NSCocoaErrorDomain]
            && error.code == NSUserCancelledError;
}

- (NSError *)admissionError:(NSString *)description {
    return [NSError errorWithDomain:VibeAudioFileMaterializationErrorDomain
                               code:VibeAudioFileMaterializationErrorAdmissionExhausted
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Every terminal outcome a caller can observe, counted in one place. Callers
// see requests, not claims, so the denominator is the waiter: a claim four
// waiters joined settles four requests. State-queue only, like everything else
// here.
- (void)countSettledRequest:(VibeAudioFileMaterializationResult)result {
    switch (result) {
        case VibeAudioFileMaterializationResultReady: _requestsReady++; break;
        case VibeAudioFileMaterializationResultFailed: _requestsFailed++; break;
        case VibeAudioFileMaterializationResultYielded: _requestsYielded++; break;
        case VibeAudioFileMaterializationResultAdmissionExhausted:
            _requestsAdmissionExhausted++;
            break;
    }
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
                completionQueue:completionQueue completion:completion];
        [self expirePendingClaimsAtTime:self->_clock() drain:NO];
        VibeAudioFileMaterializationClaim *claim = self->_claims[path];
        // The rule suspends provider transfers; a request for an already-local
        // file starts none and passes through, which is what lets the playing
        // track's tags parse the moment its open lands. Computed before this
        // request joins the table, so a foreground registration sees the world
        // it is preempting and a metadata one is judged against it.
        BOOL foregroundWasActive = [self foregroundTransferActiveLocked];
        BOOL suspendedMetadata = VibeMaterializationRoleIsMetadata(role)
                && foregroundWasActive;
        if (suspendedMetadata && (!claim || ![self claimHasNonMetadataWaiter:claim])
                && self->_datalessProbe(url)) {
            [self countSettledRequest:VibeAudioFileMaterializationResultYielded];
            [token settleWithResult:VibeAudioFileMaterializationResultYielded
                             error:nil elapsed:0];
            return;
        }
        BOOL foregroundRising = !VibeMaterializationRoleIsMetadata(role)
                && !foregroundWasActive;
        if (foregroundRising) {
            [self preemptMetadataClaimsForForegroundRiseExcludingPath:path];
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
            [self countSettledRequest:VibeAudioFileMaterializationResultAdmissionExhausted];
            [token settleWithResult:VibeAudioFileMaterializationResultAdmissionExhausted
                             error:error elapsed:0];
            [self reschedulePendingTimer];
            return;
        }
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
    // Lane capacity bounds concurrent provider transfers. A file already local
    // starts none — its run is a stat and a no-op coordinated read — so it must
    // not park behind real downloads: the playing track's metadata would wait
    // out its whole admission grace behind the scan's transfer. A file evicted
    // between this probe and the run downloads outside the bound; that race is
    // one transfer wide and self-corrects at the next admission.
    if (!_datalessProbe(claim.url)) {
        [self startClaim:claim];
        return YES;
    }

    NSMutableArray<VibeAudioFileMaterializationClaim *> *pending =
            lane == VibeMaterializationLaneInteractive
                    ? _interactivePending : _backgroundPending;
    NSUInteger maximumPending = lane == VibeMaterializationLaneInteractive
            ? _configuration.maximumInteractivePendingMaterializations
            : _configuration.maximumBackgroundPendingMaterializations;
    // No prefetch reservation or metadata eviction here anymore: a dataless
    // metadata request yields at entry whenever a foreground claim is live,
    // and a local one starts immediately, so a metadata claim can never sit
    // pending beside a prefetch — the parking contention those mechanisms
    // arbitrated is unrepresentable under the derived rule.
    if (!preserveExistingAdmission && pending.count >= maximumPending) {
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
    // Publish only real provider transfers: a local claim's run is a stat and
    // a no-op coordinated read, and a local playlist must not flash
    // indicators on every row. Same rule that exempts local claims from lane
    // capacity, and computed once so the finish cannot disagree.
    claim.publishedTransfer = _datalessProbe(claim.url);
    if (claim.publishedTransfer) {
        NSString *path = claim.path;
        NSURL *url = claim.url;
        dispatch_async(dispatch_get_main_queue(), ^{
            [CloudTransferRegistry.sharedRegistry beganTransferForPath:path url:url];
        });
    }
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
    // Every settled run un-publishes, on every exit — the runWasCancelled
    // readmission and inherited-cancel restart paths below re-begin through
    // startClaim:, and FIFO delivery to main keeps end-then-begin in order.
    if (claim.publishedTransfer) {
        claim.publishedTransfer = NO;
        NSString *transferPath = claim.path;
        dispatch_async(dispatch_get_main_queue(), ^{
            [CloudTransferRegistry.sharedRegistry endedTransferForPath:transferPath];
        });
    }
    // A Ready transfer with handle runs riding this path hands its lane slot
    // to them rather than releasing it: the AVAudioFile opens it fed are
    // still returning, and a wedged one must stay inside the same admission
    // that bounded its transfer (spec J7). The path's last run releases it.
    BOOL carrySlot = ready && !claim.runWasCancelled
            && [self pathHasLiveHandleRuns:claim.path]
            && _carriedSlotLanes[claim.path] == nil;
    if (carrySlot) {
        _carriedSlotLanes[claim.path] = @(claim.lane);
    }
    else if (claim.lane == VibeMaterializationLaneInteractive) {
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
    else if (!ready && claim.waiters.count
            && VibeMaterializationErrorIsCancellation(error)
            && claim.inheritedCancelRestarts < 2) {
        // A cancellation this coordinator did not order (its own travel
        // runWasCancelled) is the provider's dying fetch bleeding into a fresh
        // coordinated read of the same file — a play landing milliseconds
        // after a rising edge cancelled the sweep's transfer inherits it. Not
        // a verdict on the file: restart, bounded so a provider that keeps
        // answering cancelled still settles as Failed.
        claim.inheritedCancelRestarts++;
        if (![self admitClaim:claim preserveExistingAdmission:YES]) {
            [self settleClaim:claim
                       result:VibeAudioFileMaterializationResultAdmissionExhausted
                        error:[self admissionError:
                                @"Audio materialization could not be readmitted"]];
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
        [self countSettledRequest:result];
        [waiter.token settleWithResult:result error:error
                               elapsed:MAX(0, now - waiter.submittedAt)];
    }
}

- (void)yieldClaim:(VibeAudioFileMaterializationClaim *)claim {
    NSArray<VibeAudioFileMaterializationWaiter *> *waiters = claim.waiters.allValues;
    [claim.waiters removeAllObjects];
    NSTimeInterval now = _clock();
    for (VibeAudioFileMaterializationWaiter *waiter in waiters) {
        [self countSettledRequest:VibeAudioFileMaterializationResultYielded];
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
    // Belt over the rising-edge preemption: a metadata claim can sit pending
    // across a foreground registration only through a detach interleaving,
    // and it must not start while the rule is in force.
    BOOL foregroundActive = [self foregroundTransferActiveLocked];
    NSUInteger best = NSNotFound;
    for (NSUInteger index = 0; index < pending.count; index++) {
        VibeAudioFileMaterializationClaim *candidate = pending[index];
        if (foregroundActive
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
        BOOL detachedForeground = !VibeMaterializationRoleIsMetadata(waiter.role);
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
            // A metadata-only dataless remainder yields when the rule is in
            // force — and also when the departing waiter WAS the foreground:
            // its metadata waiters were passengers on the user's transfer
            // (C3's join), and a timed-out or superseded open must not leave
            // them keeping the dead transfer alive with no deadline of their
            // own. The abandoned pick returns to the sweep at its rank (B4).
            if ((detachedForeground || [self foregroundTransferActiveLocked])
                    && ![self claimHasNonMetadataWaiter:claim]
                    && self->_datalessProbe(claim.url)) {
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

#pragma mark - Stage 2: purpose-keyed AVAudioFile opens

static NSString *VibeHandleRunKey(VibeAudioFileOpenPurpose purpose, NSString *path) {
    return [NSString stringWithFormat:@"%ld:%@", (long)purpose, path];
}

- (BOOL)pathHasLiveHandleRuns:(NSString *)path {
    for (long purpose = VibeAudioFileOpenPurposePlayback;
            purpose <= VibeAudioFileOpenPurposeGapless; purpose++) {
        if (_handleRuns[VibeHandleRunKey((VibeAudioFileOpenPurpose)purpose, path)]) {
            return YES;
        }
    }
    return NO;
}

- (void)releaseCarriedSlotIfNoLiveRunsForPath:(NSString *)path {
    if ([self pathHasLiveHandleRuns:path]) {
        return;
    }
    NSNumber *lane = _carriedSlotLanes[path];
    if (lane == nil) {
        return;
    }
    [_carriedSlotLanes removeObjectForKey:path];
    if ((VibeMaterializationLane)lane.unsignedIntegerValue
            == VibeMaterializationLaneInteractive) {
        if (_interactiveRunningCount > 0) _interactiveRunningCount--;
    }
    else {
        if (_backgroundRunningCount > 0) _backgroundRunningCount--;
    }
    [self drainPendingClaims];
    [self reschedulePendingTimer];
}

- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                      completion:(VibeAudioFileOpenCompletion)completion {
    NSParameterAssert(url);
    NSParameterAssert(completionQueue);
    NSParameterAssert(completion);
    NSString *path = VibeStandardizedAudioOpenPath(url);
    NSString *key = VibeHandleRunKey(purpose, path);
    AudioFileOpenToken *token = [[AudioFileOpenToken alloc] initWithCoordinator:self
            key:key completionQueue:completionQueue completion:completion];
    dispatch_async(_stateQueue, ^{
        if (![token deliveryStillWaiting]) {
            return;
        }
        VibeAudioHandleRun *run = self->_handleRuns[key];
        if (run) {
            // Same purpose, same path: the new request replaces the delivery
            // binding without another handle open. The superseded token stays
            // silent by never taking delivery.
            run.waiter = token;
            return;
        }
        run = [[VibeAudioHandleRun alloc] init];
        run.key = key;
        run.path = path;
        run.url = url;
        run.purpose = purpose;
        run.waiter = token;
        run.submittedAt = CFAbsoluteTimeGetCurrent();
        self->_handleRuns[key] = run;
        [self startHandleRunStages:run];
    });
    return token;
}

- (void)detachOpenToken:(AudioFileOpenToken *)token {
    if (!token) {
        return;
    }
    dispatch_async(_stateQueue, ^{
        VibeAudioHandleRun *run = self->_handleRuns[token.key];
        if (run.waiter != token) {
            return; // already rebound, completed, or detached
        }
        run.waiter = nil;
        // Marked abandoned in the same step that clears the waiter, and never
        // separately: finishHandleRun: reads this to tell "the run produced
        // nothing because nobody was waiting" from "the file genuinely would
        // not open".
        run.runWasCancelled = YES;
        if (run.materializationToken) {
            // Still stage 1: nothing uncancellable has begun, so the run can
            // simply end. The transfer detach settles its own accounting.
            [run.materializationToken cancel];
            run.materializationToken = nil;
            [self->_handleRuns removeObjectForKey:run.key];
            [self releaseCarriedSlotIfNoLiveRunsForPath:run.path];
        }
        // Stage 2 already dispatched: the AVAudioFile call is uncancellable
        // and keeps the run (and its carried slot) until it returns.
    });
}

- (void)startHandleRunStages:(VibeAudioHandleRun *)run {
    run.runGeneration++;
    uint64_t runGeneration = run.runGeneration;
    if (run.purpose == VibeAudioFileOpenPurposeGapless) {
        // Stage 2 only: the parked file already proved the bytes local, and
        // the private handle must never share the parked instance. The open
        // borrows a background slot (over-subscribing briefly, like the
        // local-file fast path) so a wedged call still counts somewhere.
        if (self->_carriedSlotLanes[run.path] == nil) {
            self->_backgroundRunningCount++;
            self->_carriedSlotLanes[run.path] = @(VibeMaterializationLaneBackground);
        }
        [self dispatchHandleOpenForRun:run runGeneration:runGeneration];
        return;
    }
    VibeAudioFileMaterializationRole role = run.purpose
            == VibeAudioFileOpenPurposePlayback
            ? VibeAudioFileMaterializationRolePlayback
            : VibeAudioFileMaterializationRolePrefetch;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    run.materializationToken = [self materializeURL:run.url
                                               role:role
                                    completionQueue:_stateQueue
                                         completion:^(VibeAudioFileMaterializationResult result,
                                                      NSError *error, NSTimeInterval elapsed) {
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf handleRunTransferSettled:run runGeneration:runGeneration
                                          result:result error:error];
        }
    }];
}

- (NSError *)openErrorForMaterializationResult:(VibeAudioFileMaterializationResult)result
                                     underlying:(NSError *)underlying {
    VibeAudioFileOpenErrorCode code;
    NSString *description;
    switch (result) {
        case VibeAudioFileMaterializationResultAdmissionExhausted:
            code = VibeAudioFileOpenErrorAdmissionExhausted;
            description = @"Audio materialization capacity was exhausted";
            break;
        case VibeAudioFileMaterializationResultYielded:
            code = VibeAudioFileOpenErrorMaterializationYielded;
            description = @"Audio materialization yielded before opening the file";
            break;
        case VibeAudioFileMaterializationResultFailed:
            code = VibeAudioFileOpenErrorMaterializationFailed;
            description = @"Audio materialization failed before opening the file";
            break;
        case VibeAudioFileMaterializationResultReady:
            return nil;
    }
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (underlying) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                               code:code userInfo:userInfo];
}

- (void)handleRunTransferSettled:(VibeAudioHandleRun *)run
                    runGeneration:(uint64_t)runGeneration
                           result:(VibeAudioFileMaterializationResult)result
                            error:(NSError *)error {
    VibeAudioHandleRun *current = _handleRuns[run.key];
    if (current != run || run.runGeneration != runGeneration) {
        return;
    }
    run.materializationToken = nil;
    if (result == VibeAudioFileMaterializationResultReady) {
        [self dispatchHandleOpenForRun:run runGeneration:runGeneration];
        return;
    }
    NSError *reported = [self openErrorForMaterializationResult:result underlying:error];
    [self finishHandleRun:run runGeneration:runGeneration file:nil error:reported];
}

- (void)dispatchHandleOpenForRun:(VibeAudioHandleRun *)run
                    runGeneration:(uint64_t)runGeneration {
    if (!run.waiter) {
        // Abandoned before the uncancellable call began: nothing to open.
        [self finishHandleRun:run runGeneration:runGeneration file:nil error:nil];
        return;
    }
    dispatch_queue_t workerQueue = run.purpose == VibeAudioFileOpenPurposePlayback
            ? _interactiveWorkerQueue : _backgroundWorkerQueue;
    // Paired with the increment below rather than with finishHandleRun:, which
    // also runs for runs that never dispatched an open. The difference is the
    // count of AVAudioFile calls the OS still owes an answer for.
    atomic_fetch_add(&_handleOpensStarted, 1);
    // Snapshotted here rather than read from the ivar on the worker: the opener
    // is swappable (the debug channel's wedge injection), and a block read from
    // another thread while it is being replaced is not safe. Same discipline as
    // the open-timeout snapshot in AudioPlayer.
    VibeAudioFileOpener opener = _fileOpener;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    dispatch_async(workerQueue, ^{
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSError *error = nil;
        AVAudioFile *file = opener(run.url, &error);
        dispatch_async(strongSelf->_stateQueue, ^{
            atomic_fetch_add(&strongSelf->_handleOpensCompleted, 1);
            [strongSelf finishHandleRun:run runGeneration:runGeneration
                                   file:file error:error];
        });
    });
}

- (void)finishHandleRun:(VibeAudioHandleRun *)run
           runGeneration:(uint64_t)runGeneration
                    file:(AVAudioFile *)file
                   error:(NSError *)error {
    VibeAudioHandleRun *current = _handleRuns[run.key];
    if (current != run || run.runGeneration != runGeneration) {
        return;
    }
    AudioFileOpenToken *waiter = run.waiter;
    // A waiter may have rebound after cancellation but before the abandoned
    // stage returned. Give it a fresh run; never turn the old waiter's
    // cancellation into the new waiter's open failure.
    if (!file && waiter && run.runWasCancelled) {
        run.runWasCancelled = NO;
        [self startHandleRunStages:run];
        return;
    }
    [_handleRuns removeObjectForKey:run.key];
    [self releaseCarriedSlotIfNoLiveRunsForPath:run.path];
    if (!waiter) {
        return;
    }
    // A completion is a result, so it always carries one: either a file or a
    // reason there is none (VibeAudioFileOpenErrorAbandoned is the enforced
    // backstop, reachable only if the abandoned-run path above were defeated).
    NSError *reported = error;
    if (!file && !reported) {
        reported = [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                code:VibeAudioFileOpenErrorAbandoned
                userInfo:@{NSLocalizedDescriptionKey:
                        @"The audio file open was abandoned before it produced a result"}];
    }
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - run.submittedAt;
    dispatch_async(waiter.completionQueue, ^{
        VibeAudioFileOpenCompletion completion = [waiter takeCompletionForDelivery];
        if (completion) {
            completion(file, reported, elapsed);
        }
    });
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
        snapshot.handleRunCount = self->_handleRuns.count;
        snapshot.foregroundTransferActive = [self foregroundTransferActiveLocked];
        snapshot.handleOpensStarted = self->_handleOpensStarted;
        snapshot.handleOpensCompleted = self->_handleOpensCompleted;
        snapshot.requestsReady = self->_requestsReady;
        snapshot.requestsFailed = self->_requestsFailed;
        snapshot.requestsYielded = self->_requestsYielded;
        snapshot.requestsAdmissionExhausted = self->_requestsAdmissionExhausted;
    }];
    return snapshot;
}

- (void)expirePendingClaimsForTesting {
    [self performStateSynchronously:^{
        [self expirePendingClaimsAtTime:self->_clock() drain:YES];
    }];
}

@end
