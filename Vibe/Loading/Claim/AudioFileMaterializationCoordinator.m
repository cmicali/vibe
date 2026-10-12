//
//  AudioFileMaterializationCoordinator.m
//  Vibe
//

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioFileMaterializationTokens.h"
#import "AudioFileHandle.h"

#import "AudioFileOpenRules.h"
#import "AudioTrack.h"
#import "AudioWorkScheduler.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistryInternal.h"
#import "NSURL+Hash.h"
#import "PlaceholderFiles.h"

#import <os/lock.h>

#include <float.h>
#include <stdatomic.h>

NSString * const VibeAudioFileMaterializationErrorDomain =
        @"com.vibe.audio-file-materialization";
NSString * const VibeAudioFileOpenErrorDomain = @"com.vibe.audio-file-open";

@implementation VibeAudioHandleRun
@end

@implementation VibeAudioFileMaterializationWaiter
@end

@implementation VibeDatalessProbeActivity {
    _Atomic uint64_t _attemptCount;
}

- (void)beginAttempt {
    atomic_fetch_add(&_attemptCount, 1);
}

- (void)finishAttempt {
    atomic_fetch_sub(&_attemptCount, 1);
}

- (uint64_t)attemptCount {
    return atomic_load(&_attemptCount);
}

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

- (BOOL)runOnReadable:(dispatch_block_t)onReadable error:(NSError *__autoreleasing *)error {
    return [_materializer materializeURL:_url token:_token onReadable:onReadable error:error];
}

- (void)cancel {
    [_materializer cancel];
}

@end

static void *VibeMaterializationStateQueueKey = &VibeMaterializationStateQueueKey;
static const NSUInteger kMaximumDatalessProbeRunningCount = 8;
static const NSUInteger kMaximumDatalessProbePendingCount = 16;
static const NSTimeInterval kDatalessProbePendingGrace = 5;

@implementation AudioFileMaterializationCoordinator {
    // Here, not in the class extension, since a shipping header has no #if DEBUG.
#if DEBUG
    // Atomic for the health probe's lock-free read; written on the state queue.
    _Atomic uint64_t _handleOpensStarted;
    _Atomic uint64_t _handleOpensCompleted;
    uint64_t _requestsReady;
    uint64_t _requestsFailed;
    uint64_t _requestsYielded;
    uint64_t _requestsAdmissionExhausted;
#endif
}

+ (instancetype)sharedCoordinator {
    static AudioFileMaterializationCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

static VibeAudioFileOpener const kProductionFileOpener =
        ^AudioFileHandle *(NSURL *url, BOOL (^interrupted)(void), NSError **error) {
    return [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:interrupted error:error];
};

- (instancetype)init {
    return [self initWithFileOpener:kProductionFileOpener];
}

- (instancetype)initWithFileOpener:(VibeAudioFileOpener)fileOpener {
    AudioLoadingConfiguration *configuration = [AudioLoadingConfiguration productionConfiguration];
    return [self initWithConfiguration:configuration
                      operationFactory:^id<AudioFileMaterializationOperation>(
                              NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[VibeCloudFileMaterializationOperation alloc] initWithURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        return [PlaceholderFiles isDatalessFile:url];
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
                            fileOpener:kProductionFileOpener];
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
        _interactivePending = [NSMutableArray array];
        _backgroundPending = [NSMutableArray array];
        _datalessProbeActivity = [[VibeDatalessProbeActivity alloc] init];
        _stateQueue = dispatch_queue_create("com.vibe.materialization.state", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_stateQueue, VibeMaterializationStateQueueKey,
                                    (__bridge void *)self, NULL);
        _datalessProbeScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.materialization.dataless-probe"
                qualityOfService:QOS_CLASS_USER_INITIATED
                maximumRunningCount:kMaximumDatalessProbeRunningCount
                maximumPendingCount:kMaximumDatalessProbePendingCount
                pendingGrace:kDatalessProbePendingGrace];
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

// A readable stream's open in flight or handle alive: its playback and
// prefetch waiters were served, but what they opened still reads the transfer.
- (BOOL)streamIsReadForClaim:(VibeAudioFileMaterializationClaim *)claim {
    return claim.availability.readerCount > 0;
}

// A playback or prefetch waiter, or a stream one of their handles reads.
- (BOOL)claimServesForeground:(VibeAudioFileMaterializationClaim *)claim {
    if (claim.waiters.count) {
        for (VibeAudioFileMaterializationWaiter *waiter in claim.waiters.objectEnumerator) {
            if (!VibeMaterializationRoleIsMetadata(waiter.role)) {
                return YES;
            }
        }
    }
    return [self streamIsReadForClaim:claim];
}

// Derived from the claim table, never counted: claims leave at settlement, and
// the drainPendingClaims every settlement and every stream's last reader runs
// is the release. O(claims), a table bounded by the probe, lane and
// caller-side admissions.
- (BOOL)foregroundTransferActiveLocked {
    for (VibeAudioFileMaterializationClaim *claim in _claims.objectEnumerator) {
        if ([self claimServesForeground:claim]) {
            return YES;
        }
    }
    return NO;
}

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

- (uint64_t)datalessProbesInFlight {
    return _datalessProbeActivity.attemptCount;
}

- (BOOL)isForegroundTransferActive {
    __block BOOL active;
    [self performStateSynchronously:^{
        active = [self foregroundTransferActiveLocked];
    }];
    return active;
}

// The rising edge yields every metadata-only dataless claim, running ones
// included: the sweep's download is cancelled, not waited out (C6). The path
// being joined is exempt, or the request would cancel the transfer it came
// for (A2: one transfer per path).
- (void)preemptMetadataClaimsForForegroundRiseExcludingPath:(NSString *)joinedPath {
    NSArray<VibeAudioFileMaterializationClaim *> *claims = _claims.allValues;
    for (VibeAudioFileMaterializationClaim *claim in claims) {
        if ([claim.path isEqualToString:joinedPath]) {
            continue;
        }
        // Not yet in a provider operation; the probe's settlement rechecks
        // the hold before entering one.
        if (claim.state == VibeMaterializationClaimStateProbing
                || claim.state == VibeMaterializationClaimStateRefreshing) {
            continue;
        }
        if (claim.waiters.count && ![self claimServesForeground:claim]
                && claim.dataless) {
            [self yieldClaim:claim];
        }
    }
}

// VibeMaterializationCancelledError's spelling, which NSFileCoordinator's
// -cancel also returns.
static BOOL VibeMaterializationErrorIsCancellation(NSError *error) {
    return [error.domain isEqualToString:NSCocoaErrorDomain]
            && error.code == NSUserCancelledError;
}

- (NSError *)admissionError:(NSString *)description {
    return [NSError errorWithDomain:VibeAudioFileMaterializationErrorDomain
                               code:VibeAudioFileMaterializationErrorAdmissionExhausted
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Counts per waiter: a claim four waiters joined settles four requests.
- (void)countSettledRequest:(VibeAudioFileMaterializationResult)result {
#if DEBUG
    switch (result) {
        case VibeAudioFileMaterializationResultReady: _requestsReady++; break;
        case VibeAudioFileMaterializationResultFailed: _requestsFailed++; break;
        case VibeAudioFileMaterializationResultYielded: _requestsYielded++; break;
        case VibeAudioFileMaterializationResultAdmissionExhausted:
            _requestsAdmissionExhausted++;
            break;
    }
#endif
}

- (NSError *)missingFailureError {
    return [NSError errorWithDomain:VibeAudioFileMaterializationErrorDomain
                               code:VibeAudioFileMaterializationErrorFailed
                           userInfo:@{NSLocalizedDescriptionKey:
                                          @"Audio file materialization failed"}];
}

- (void)finishInitialProbeForClaim:(VibeAudioFileMaterializationClaim *)claim
                          dataless:(BOOL)dataless {
    if (_claims[claim.path] != claim
            || claim.state != VibeMaterializationClaimStateProbing
            || !claim.waiters.count) {
        return;
    }
    claim.probeToken = nil;
    claim.dataless = dataless;
    if (dataless) {
        for (VibeAudioHandleRun *run in _handleRuns.objectEnumerator) {
            if ([run.path isEqualToString:claim.path]) {
                [self notifyDatalessForRun:run];
            }
        }
    }
    BOOL metadataOnly = ![self claimServesForeground:claim];
    if (dataless && metadataOnly
            && ([self foregroundTransferActiveLocked]
                    || claim.yieldIfDatalessAfterProbe)) {
        claim.yieldIfDatalessAfterProbe = NO;
        [self settleClaim:claim result:VibeAudioFileMaterializationResultYielded error:nil];
    }
    else {
        claim.yieldIfDatalessAfterProbe = NO;
        if (![self admitClaim:claim
                preserveExistingAdmission:NO
                      classificationFresh:YES]) {
            [self settleClaim:claim
                       result:VibeAudioFileMaterializationResultAdmissionExhausted
                        error:[self admissionError:
                                @"Audio materialization capacity has no pending slot"]];
        }
    }
    [self drainPendingClaims];
    [self reschedulePendingTimer];
}

- (void)initialProbeAdmissionFailedForClaim:(VibeAudioFileMaterializationClaim *)claim
                                     reason:(VibeAudioWorkAdmissionFailure)reason {
    if (_claims[claim.path] != claim
            || claim.state != VibeMaterializationClaimStateProbing
            || !claim.waiters.count) {
        return;
    }
    claim.probeToken = nil;
    NSString *description = reason == VibeAudioWorkAdmissionFailureWaitExpired
            ? @"Audio file classification stayed pending past its admission grace"
            : @"Audio file classification capacity has no pending slot";
    [self settleClaim:claim
               result:VibeAudioFileMaterializationResultAdmissionExhausted
                error:[self admissionError:description]];
    [self drainPendingClaims];
    [self reschedulePendingTimer];
}

- (void)submitInitialProbeForClaim:(VibeAudioFileMaterializationClaim *)claim {
    VibeAudioFileMaterializationDatalessProbe probe = _datalessProbe;
    VibeDatalessProbeActivity *activity = _datalessProbeActivity;
    NSURL *url = claim.url;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    __weak VibeAudioFileMaterializationClaim *weakClaim = claim;
    [activity beginAttempt];
    claim.probeToken = [_datalessProbeScheduler submitWork:^{
        BOOL dataless = probe(url);
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        VibeAudioFileMaterializationClaim *strongClaim = weakClaim;
        if (!strongSelf || !strongClaim) {
            [activity finishAttempt];
            return;
        }
        dispatch_async(strongSelf->_stateQueue, ^{
            [strongSelf finishInitialProbeForClaim:strongClaim dataless:dataless];
            [activity finishAttempt];
        });
    } failureQueue:_stateQueue
    admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        VibeAudioFileMaterializationClaim *strongClaim = weakClaim;
        if (strongSelf && strongClaim) {
            [strongSelf initialProbeAdmissionFailedForClaim:strongClaim reason:failure];
        }
        [activity finishAttempt];
    }];
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
        // Sampled before this request joins the table. An already-local file
        // passes: the rule suspends provider transfers, and it starts none.
        BOOL foregroundWasActive = [self foregroundTransferActiveLocked];
        BOOL suspendedMetadata = VibeMaterializationRoleIsMetadata(role)
                && foregroundWasActive;
        BOOL claimClassificationIsKnown = claim
                && claim.state != VibeMaterializationClaimStateProbing
                && claim.state != VibeMaterializationClaimStateRefreshing;
        if (suspendedMetadata && claimClassificationIsKnown
                && ![self claimServesForeground:claim] && claim.dataless) {
            [self countSettledRequest:VibeAudioFileMaterializationResultYielded];
            [token settleWithResult:VibeAudioFileMaterializationResultYielded
                             error:nil elapsed:0];
            return;
        }
        BOOL foregroundRising = !VibeMaterializationRoleIsMetadata(role)
                && !foregroundWasActive;
        VibeAudioFileMaterializationWaiter *waiter =
                [[VibeAudioFileMaterializationWaiter alloc] init];
        waiter.identifier = identifier;
        waiter.role = role;
        waiter.submittedAt = self->_clock();
        waiter.token = token;
        // Preempt only after this waiter is installed, so cancellation side
        // effects already see the hold.
        if (claim) {
            VibeAudioFileMaterializationRole oldRole = claim.effectiveRole;
            claim.waiters[@(identifier)] = waiter;
            claim.effectiveRole = [self effectiveRoleForClaim:claim];
            if ([self claimServesForeground:claim]) {
                claim.yieldIfDatalessAfterProbe = NO;
            }
            if (claim.state == VibeMaterializationClaimStatePending
                    && claim.effectiveRole != oldRole) {
                [self readmitPendingClaim:claim];
            }
            if (claim.availability && !VibeMaterializationRoleIsMetadata(role)) {
                // Next turn: a handle run sets its token after this returns,
                // and the installed waiter holds the stream until then.
                uint64_t runGeneration = claim.runGeneration;
                dispatch_async(self->_stateQueue, ^{
                    [self serveReadableClaim:claim runGeneration:runGeneration];
                });
            }
            if (foregroundRising) {
                [self preemptMetadataClaimsForForegroundRiseExcludingPath:path];
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
        claim.state = VibeMaterializationClaimStateProbing;
        claim.ordinal = ++self->_nextClaimOrdinal;
        self->_claims[path] = claim;
        [self submitInitialProbeForClaim:claim];
        if (foregroundRising) {
            [self preemptMetadataClaimsForForegroundRiseExcludingPath:path];
        }
        [self drainPendingClaims];
        [self reschedulePendingTimer];
    }];
    return token;
}

- (BOOL)admitClaim:(VibeAudioFileMaterializationClaim *)claim
        preserveExistingAdmission:(BOOL)preserveExistingAdmission
              classificationFresh:(BOOL)classificationFresh {
    VibeMaterializationLane lane = VibeLaneForRole(claim.effectiveRole);
    claim.lane = lane;
    NSUInteger running = lane == VibeMaterializationLaneInteractive
            ? _interactiveRunningCount : _backgroundRunningCount;
    NSUInteger maximumRunning = lane == VibeMaterializationLaneInteractive
            ? _configuration.maximumInteractiveMaterializations
            : _configuration.maximumBackgroundMaterializations;
    // Lanes bound provider transfers; a local file starts none, so it never
    // parks behind one. A file evicted after classification downloads outside
    // the bound, one transfer wide.
    if (!claim.dataless || running < maximumRunning) {
        [self startClaim:claim classificationFresh:classificationFresh];
        return YES;
    }

    NSMutableArray<VibeAudioFileMaterializationClaim *> *pending =
            lane == VibeMaterializationLaneInteractive
                    ? _interactivePending : _backgroundPending;
    NSUInteger maximumPending = lane == VibeMaterializationLaneInteractive
            ? _configuration.maximumInteractivePendingMaterializations
            : _configuration.maximumBackgroundPendingMaterializations;
    // Needs no prefetch reservation: while a foreground claim is live,
    // metadata-only dataless work yields at entry or at its probe, so none
    // holds a pending slot beside a prefetch.
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
    [self admitClaim:claim
            preserveExistingAdmission:YES
                  classificationFresh:NO];
}

- (void)publishTransferBeginForClaim:(VibeAudioFileMaterializationClaim *)claim {
    NSString *path = claim.path;
    NSURL *url = claim.url;
    run_on_main_thread({
        [CloudTransferRegistry.sharedRegistry beganTransferForPath:path url:url];
    });
}

- (BOOL)finishStartRefreshForClaim:(VibeAudioFileMaterializationClaim *)claim
                     runGeneration:(uint64_t)runGeneration
                          dataless:(BOOL)dataless {
    BOOL refreshOwnsLane = _claims[claim.path] == claim
            && claim.runGeneration == runGeneration
            && claim.state == VibeMaterializationClaimStateRefreshing;
    NSAssert(refreshOwnsLane,
             @"A refresh result must match the run which still owns its reserved lane");
    if (!refreshOwnsLane) {
        return NO;
    }
    claim.dataless = dataless;
    BOOL metadataMustYield = claim.waiters.count && dataless
            && ![self claimServesForeground:claim]
            && ([self foregroundTransferActiveLocked]
                    || claim.yieldIfDatalessAfterProbe);
    if (metadataMustYield) {
        [self yieldClaim:claim];
        [self finishClaim:claim runGeneration:runGeneration ready:NO error:nil];
        return NO;
    }
    if (claim.runWasCancelled || !claim.waiters.count) {
        if (!claim.runWasCancelled) {
            claim.runWasCancelled = YES;
            [claim.operation cancel];
        }
        // Finish in this turn, so no waiter can attach and revive the run.
        [self finishClaim:claim runGeneration:runGeneration ready:NO error:nil];
        return NO;
    }

    claim.yieldIfDatalessAfterProbe = NO;
    claim.state = VibeMaterializationClaimStateRunning;
    if (claim.dataless) {
        [self publishTransferBeginForClaim:claim];
    }
    else {
        // Local by the time its turn came: the reserved slot goes to the next
        // transfer rather than wait out this read.
        [self releaseLaneForClaim:claim];
        [self drainPendingClaims];
    }
    return YES;
}

// A download can install another version than its placeholder stood for (a
// file re-uploaded since its folder was listed), so every track's memoized
// key is retired when the file's own key moved: its waveform and metadata
// must not be filed under, or served from, the old version's entries. Only a
// dataless file downloads, so only its key is taken, each a stat and a hash.
static BOOL VibeRunMaterialization(id<AudioFileMaterializationOperation> operation, NSURL *url, BOOL dataless,
                                   dispatch_block_t onReadable, NSError *__autoreleasing *error) {
    NSString *placeholderKey = dataless ? [url cacheKey] : nil;
    BOOL ready = [operation runOnReadable:onReadable error:error];
    if (ready && placeholderKey && ![placeholderKey isEqualToString:[url cacheKey]]) {
        LogInfo(@"%@ downloaded as another version than its placeholder's; re-keying", url.lastPathComponent);
        [AudioTrack invalidateMemoizedCacheKeys];
    }
    return ready;
}

- (void)startClaim:(VibeAudioFileMaterializationClaim *)claim
        classificationFresh:(BOOL)classificationFresh {
    BOOL refreshBeforeStart = claim.dataless && !classificationFresh;
    claim.lane = VibeLaneForRole(claim.effectiveRole);
    claim.runGeneration++;
    claim.runWasCancelled = NO;
    uint64_t runGeneration = claim.runGeneration;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    if (!claim.dataless && classificationFresh) {
        // A fresh local answer is the run's answer: no operation, no lane, no
        // worker. It settles in a later turn, as a run would, so no admission
        // or drain has its claim finished underneath it.
        claim.state = VibeMaterializationClaimStateRunning;
        claim.holdsLane = NO;
        dispatch_async(_stateQueue, ^{
            [weakSelf finishClaim:claim runGeneration:runGeneration ready:YES error:nil];
        });
        return;
    }
    id<AudioFileMaterializationOperation> operation =
            _operationFactory(claim.url, claim.effectiveRole);
    if (!operation) {
        // Nothing entered Running, so there is no begin to pair.
        [self settleClaim:claim result:VibeAudioFileMaterializationResultFailed
                    error:[self missingFailureError]];
        return;
    }
    claim.operation = operation;

    claim.holdsLane = claim.dataless;
    if (claim.holdsLane) {
        if (claim.lane == VibeMaterializationLaneInteractive) {
            _interactiveRunningCount++;
        }
        else {
            _backgroundRunningCount++;
        }
    }

    dispatch_queue_t workerQueue = claim.lane == VibeMaterializationLaneInteractive
            ? _interactiveWorkerQueue : _backgroundWorkerQueue;
    dispatch_block_t onReadable = ^{
        // TRAP: called on the remote client's delivery queue, which every
        // download shares, and it can race a cancel: hop, never block, and let
        // the state queue match the run.
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(strongSelf->_stateQueue, ^{
                [strongSelf claimBecameReadable:claim runGeneration:runGeneration];
            });
        }
    };
    NSURL *url = claim.url;
    if (refreshBeforeStart) {
        claim.state = VibeMaterializationClaimStateRefreshing;
        VibeAudioFileMaterializationDatalessProbe probe = _datalessProbe;
        VibeDatalessProbeActivity *activity = _datalessProbeActivity;
        [activity beginAttempt];
        dispatch_async(workerQueue, ^{
            BOOL dataless = probe(url);
            AudioFileMaterializationCoordinator *strongSelf = weakSelf;
            if (!strongSelf) {
                [activity finishAttempt];
                return;
            }
            __block BOOL shouldRun = NO;
            dispatch_sync(strongSelf->_stateQueue, ^{
                shouldRun = [strongSelf finishStartRefreshForClaim:claim
                        runGeneration:runGeneration dataless:dataless];
            });
            [activity finishAttempt];
            strongSelf = nil;
            if (!shouldRun) {
                return;
            }
            // Found local just now: as fresh an answer as the initial probe's.
            NSError *error = nil;
            BOOL ready = !dataless || VibeRunMaterialization(operation, url, YES, onReadable, &error);
            AudioFileMaterializationCoordinator *completionSelf = weakSelf;
            if (completionSelf) {
                dispatch_async(completionSelf->_stateQueue, ^{
                    [completionSelf finishClaim:claim runGeneration:runGeneration
                                           ready:ready error:error];
                });
            }
        });
        return;
    }

    claim.state = VibeMaterializationClaimStateRunning;
    if (claim.dataless) {
        [self publishTransferBeginForClaim:claim];
    }
    BOOL dataless = claim.dataless;
    dispatch_async(workerQueue, ^{
        NSError *error = nil;
        BOOL ready = VibeRunMaterialization(operation, url, dataless, onReadable, &error);
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
            || (claim.state != VibeMaterializationClaimStateRefreshing
                    && claim.state != VibeMaterializationClaimStateRunning)) {
        return;
    }
    BOOL classificationFresh = claim.state == VibeMaterializationClaimStateRefreshing;
    // Running+dataless means begin was published; Refreshing published
    // nothing. A restart below re-begins, and main-queue FIFO keeps the order.
    if (claim.state == VibeMaterializationClaimStateRunning && claim.dataless) {
        NSString *transferPath = claim.path;
        run_on_main_thread({
            [CloudTransferRegistry.sharedRegistry endedTransferForPath:transferPath];
        });
    }
    [self releaseLaneForClaim:claim];
    claim.operation = nil;
    claim.availability.onLastReaderGone = nil;
    claim.availability = nil;
    if (ready) {
        claim.dataless = NO;
    }

    if (claim.runWasCancelled) {
        claim.runWasCancelled = NO;
        if (claim.waiters.count) {
            if (![self admitClaim:claim
                    preserveExistingAdmission:YES
                          classificationFresh:classificationFresh]) {
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
        // A cancellation this coordinator did not order (ours set
        // runWasCancelled) is a dying fetch, e.g. the sweep's just-yielded
        // transfer, bleeding into a fresh read of the same file. Restart,
        // bounded so a provider that keeps answering cancelled still fails.
        claim.inheritedCancelRestarts++;
        if (![self admitClaim:claim
                preserveExistingAdmission:YES
                      classificationFresh:NO]) {
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

// A run's slot goes back when it settles, or earlier when its start refresh
// finds the file local. A local run holds none: nothing times a running read
// out, so one stalled on a hung SMB or NFS share or a sleeping disk would keep
// the one-wide background lane, and every cloud row's metadata behind it, for
// as long as it blocked.
- (void)releaseLaneForClaim:(VibeAudioFileMaterializationClaim *)claim {
    if (!claim.holdsLane) {
        return;
    }
    claim.holdsLane = NO;
    if (claim.lane == VibeMaterializationLaneInteractive) {
        if (_interactiveRunningCount > 0) _interactiveRunningCount--;
    }
    else {
        if (_backgroundRunningCount > 0) _backgroundRunningCount--;
    }
}

- (BOOL)claim:(VibeAudioFileMaterializationClaim *)claim isRunningGeneration:(uint64_t)runGeneration {
    return claim && _claims[claim.path] == claim && claim.runGeneration == runGeneration
            && claim.state == VibeMaterializationClaimStateRunning && !claim.runWasCancelled;
}

// The remote fetch's onReadable: the run stays Running, holding its lane and
// its registry entry, and its playback and prefetch waiters are served now.
- (void)claimBecameReadable:(VibeAudioFileMaterializationClaim *)claim
              runGeneration:(uint64_t)runGeneration {
    if (![self claim:claim isRunningGeneration:runGeneration] || claim.availability) {
        return;
    }
    // Nil only once the transfer has finished, and its completion is coming.
    CloudFileAvailability *availability = [CloudFileMaterializer availabilityForURL:claim.url];
    if (!availability) {
        return;
    }
    claim.availability = availability;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    __weak VibeAudioFileMaterializationClaim *weakClaim = claim;
    availability.onLastReaderGone = ^{
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(strongSelf->_stateQueue, ^{
                [strongSelf streamReleasedForClaim:weakClaim runGeneration:runGeneration];
            });
        }
    };
    [self serveReadableClaim:claim runGeneration:runGeneration];
}

// Each playback and prefetch waiter leaves as a Ready would settle it. A
// handle run's open is dispatched in this turn, never through its token, so
// the open holds the stream from the waiter's leaving onward.
- (void)serveReadableClaim:(VibeAudioFileMaterializationClaim *)claim
             runGeneration:(uint64_t)runGeneration {
    if (![self claim:claim isRunningGeneration:runGeneration] || !claim.availability) {
        return;
    }
    NSTimeInterval now = _clock();
    for (VibeAudioFileMaterializationWaiter *waiter in claim.waiters.allValues) {
        if (VibeMaterializationRoleIsMetadata(waiter.role)) {
            continue;
        }
        [claim.waiters removeObjectForKey:@(waiter.identifier)];
        [self countSettledRequest:VibeAudioFileMaterializationResultReady];
        VibeAudioHandleRun *served = nil;
        for (VibeAudioHandleRun *run in _handleRuns.objectEnumerator) {
            if (run.materializationToken == waiter.token) {
                served = run;
                break;
            }
        }
        if (served) {
            [self handleRunTransferSettled:served runGeneration:served.runGeneration
                                    result:VibeAudioFileMaterializationResultReady error:nil];
        }
        else {
            [waiter.token settleWithResult:VibeAudioFileMaterializationResultReady error:nil
                                   elapsed:MAX(0, now - waiter.submittedAt)];
        }
    }
    // What a restart of this run would be admitted as; the lane held now is
    // released by claim.lane, which stays.
    claim.effectiveRole = [self effectiveRoleForClaim:claim];
}

// Nobody waits and no handle reads: the transfer stops, as it does when a
// run's last waiter leaves. TRAP: a readable stream's served handles hold it,
// so an empty waiter table alone does not abandon it, and its last reader
// leaving (onLastReaderGone, a failed or interrupted open) must ask again.
- (void)cancelRunIfAbandoned:(VibeAudioFileMaterializationClaim *)claim {
    if (claim.waiters.count || [self streamIsReadForClaim:claim]) {
        return;
    }
    claim.runWasCancelled = YES;
    [claim.operation cancel];
}

// The availability's last holder left (onLastReaderGone).
- (void)streamReleasedForClaim:(VibeAudioFileMaterializationClaim *)claim
                 runGeneration:(uint64_t)runGeneration {
    if (![self claim:claim isRunningGeneration:runGeneration] || !claim.availability) {
        return;
    }
    [self cancelRunIfAbandoned:claim];
    // The hold may have dropped with it.
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
    NSAssert(claim.state != VibeMaterializationClaimStateProbing,
             @"An unclassified claim must settle through its probe");
    if (claim.state == VibeMaterializationClaimStatePending) {
        [self settleClaim:claim
                   result:VibeAudioFileMaterializationResultYielded
                    error:nil];
        return;
    }
    NSArray<VibeAudioFileMaterializationWaiter *> *waiters = claim.waiters.allValues;
    [claim.waiters removeAllObjects];
    NSTimeInterval now = _clock();
    for (VibeAudioFileMaterializationWaiter *waiter in waiters) {
        [self countSettledRequest:VibeAudioFileMaterializationResultYielded];
        [waiter.token settleWithResult:VibeAudioFileMaterializationResultYielded
                                 error:nil elapsed:MAX(0, now - waiter.submittedAt)];
    }
    if (claim.state == VibeMaterializationClaimStateRefreshing
            || claim.state == VibeMaterializationClaimStateRunning) {
        claim.runWasCancelled = YES;
        [claim.operation cancel];
    }
}

- (NSUInteger)bestPendingIndexInArray:(NSArray<VibeAudioFileMaterializationClaim *> *)pending {
    // Backs up the rising-edge preemption: a detach interleaving can leave a
    // metadata claim pending under the rule, and it must not start.
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
        [self startClaim:claim classificationFresh:NO];
    }
    while (_backgroundRunningCount < _configuration.maximumBackgroundMaterializations) {
        NSUInteger index = [self bestPendingIndexInArray:_backgroundPending];
        if (index == NSNotFound) break;
        VibeAudioFileMaterializationClaim *claim = _backgroundPending[index];
        [_backgroundPending removeObjectAtIndex:index];
        [self startClaim:claim classificationFresh:NO];
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
            if (claim.state == VibeMaterializationClaimStateProbing) {
                if ([claim.probeToken cancelIfPending]) {
                    [self->_datalessProbeActivity finishAttempt];
                }
                claim.probeToken = nil;
                if (self->_claims[claim.path] == claim) {
                    [self->_claims removeObjectForKey:claim.path];
                }
            }
            else if (claim.state == VibeMaterializationClaimStatePending) {
                [self removePendingClaim:claim];
                if (self->_claims[claim.path] == claim) {
                    [self->_claims removeObjectForKey:claim.path];
                }
            }
            else {
                [self cancelRunIfAbandoned:claim];
            }
        }
        else {
            claim.effectiveRole = [self effectiveRoleForClaim:claim];
            // A metadata-only dataless remainder yields under the rule, and
            // also when the foreground itself left: its passengers (C3) must
            // not keep a dead open's transfer alive with no deadline of their
            // own. The pick returns to the sweep at its rank (B4).
            BOOL metadataOnly = ![self claimServesForeground:claim];
            BOOL probeOutstanding = claim.state == VibeMaterializationClaimStateProbing
                    || claim.state == VibeMaterializationClaimStateRefreshing;
            if (!metadataOnly) {
                claim.yieldIfDatalessAfterProbe = NO;
            }
            else if (detachedForeground && probeOutstanding) {
                claim.yieldIfDatalessAfterProbe = YES;
            }
            else if (!probeOutstanding && claim.dataless
                    && (detachedForeground || [self foregroundTransferActiveLocked])) {
                [self yieldClaim:claim];
            }
            if (self->_claims[claim.path] == claim
                    && claim.state == VibeMaterializationClaimStatePending
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

- (VibeAudioFileMaterializationCoordinatorSnapshot)stateSnapshotForTesting {
    __block VibeAudioFileMaterializationCoordinatorSnapshot snapshot = {0};
    [self performStateSynchronously:^{
        snapshot.claimCount = self->_claims.count;
        snapshot.waiterCount = 0;
        for (VibeAudioFileMaterializationClaim *claim in self->_claims.objectEnumerator) {
            snapshot.waiterCount += claim.waiters.count;
            snapshot.readableClaimCount += claim.availability != nil;
        }
        snapshot.interactiveRunningCount = self->_interactiveRunningCount;
        snapshot.backgroundRunningCount = self->_backgroundRunningCount;
        snapshot.interactivePendingCount = self->_interactivePending.count;
        snapshot.backgroundPendingCount = self->_backgroundPending.count;
        snapshot.handleRunCount = self->_handleRuns.count;
        snapshot.datalessProbesInFlight = [self datalessProbesInFlight];
        snapshot.foregroundTransferActive = [self foregroundTransferActiveLocked];
#if DEBUG
        snapshot.handleOpensStarted = self->_handleOpensStarted;
        snapshot.handleOpensCompleted = self->_handleOpensCompleted;
        snapshot.requestsReady = self->_requestsReady;
        snapshot.requestsFailed = self->_requestsFailed;
        snapshot.requestsYielded = self->_requestsYielded;
        snapshot.requestsAdmissionExhausted = self->_requestsAdmissionExhausted;
#endif
    }];
    return snapshot;
}

#if DEBUG
// Started first: an open racing the two loads reads low, never one high,
// which quiescence's zero-at-rest check would report as a stranded open.
- (uint64_t)handleOpensInFlight {
    uint64_t started = atomic_load(&_handleOpensStarted);
    uint64_t completed = atomic_load(&_handleOpensCompleted);
    return started > completed ? started - completed : 0;
}

- (void)countHandleOpenStarted {
    atomic_fetch_add(&_handleOpensStarted, 1);
}

- (void)countHandleOpenCompleted {
    atomic_fetch_add(&_handleOpensCompleted, 1);
}
#endif

@end
