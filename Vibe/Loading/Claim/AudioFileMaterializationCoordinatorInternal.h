//
//  AudioFileMaterializationCoordinatorInternal.h
//  Vibe
//

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioFileMaterializationOperation <NSObject>

// Background only. cancel returns at once, before or during the run.
// onReadable, called at most once from any thread and returning at once, says
// the file can be opened before the run completes (CloudFileRemoteFetch);
// an operation that cannot stream never calls it.
- (BOOL)runOnReadable:(dispatch_block_t)onReadable
                error:(NSError *__autoreleasing _Nullable *_Nullable)error;
- (void)cancel;

@end

typedef id<AudioFileMaterializationOperation> _Nonnull
        (^VibeAudioFileMaterializationOperationFactory)(
                NSURL *url, VibeAudioFileMaterializationRole role);
typedef NSTimeInterval (^VibeAudioFileMaterializationClock)(void);
// YES when the contents are not local (production: PlaceholderFiles.isDatalessFile:).
// Called concurrently on bounded workers; may block. An initial NO bypasses
// transfer admission. A refresh's NO releases its reserved lane and settles
// Ready without running the materialization operation.
typedef BOOL (^VibeAudioFileMaterializationDatalessProbe)(NSURL *url);
// Stage 2's one AudioFileHandle call. interrupted answers YES once the run is
// cancelled, and the open's waits for a streaming file's bytes end on it.
typedef AudioFileHandle * _Nullable (^VibeAudioFileOpener)(
        NSURL *url, BOOL (^interrupted)(void),
        NSError * _Nullable __autoreleasing * _Nullable error);

typedef struct {
    NSUInteger claimCount;
    NSUInteger waiterCount;
    NSUInteger interactiveRunningCount;
    NSUInteger backgroundRunningCount;
    NSUInteger interactivePendingCount;
    NSUInteger backgroundPendingCount;
    NSUInteger handleRunCount;
    uint64_t datalessProbesInFlight;
    BOOL foregroundTransferActive;
    // Running claims a stream's handles were served from before completion.
    NSUInteger readableClaimCount;
    // Cumulative, and zero outside debug builds: the gauges above cannot tell
    // idle from busy, which is what a silent stall looks like.
    // handleOpensStarted - handleOpensCompleted is the outstanding
    // AudioFileHandle calls, zero at rest.
    uint64_t handleOpensStarted;
    uint64_t handleOpensCompleted;
    uint64_t requestsReady;
    uint64_t requestsFailed;
    uint64_t requestsYielded;
    uint64_t requestsAdmissionExhausted;
} VibeAudioFileMaterializationCoordinatorSnapshot;

typedef NS_ENUM(NSUInteger, VibeMaterializationLane) {
    VibeMaterializationLaneInteractive = 0,
    VibeMaterializationLaneBackground,
};

typedef NS_ENUM(NSUInteger, VibeMaterializationClaimState) {
    VibeMaterializationClaimStateProbing = 0,
    VibeMaterializationClaimStatePending,
    VibeMaterializationClaimStateRefreshing,
    VibeMaterializationClaimStateRunning,
};

@class AudioWorkScheduler;
@class AudioWorkToken;
@class CloudFileAvailability;

// Stage 2: one purpose's AudioFileHandle open for one standardized path,
// riding the path's stage-1 claim.
@interface VibeAudioHandleRun : NSObject
@property (nonatomic, copy) NSString *key;         // "purpose:path"
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) VibeAudioFileOpenPurpose purpose;
@property (nonatomic, strong, nullable) AudioFileOpenToken *waiter;
@property (nonatomic, strong, nullable) AudioFileMaterializationRequestToken *materializationToken;
@property (nonatomic) uint64_t runGeneration;
@property (nonatomic) BOOL runWasCancelled;
// What the open's interrupted block answers, read on its worker.
@property (atomic) BOOL openInterrupted;
@property (nonatomic) NSTimeInterval submittedAt;
@end

@interface VibeAudioFileMaterializationWaiter : NSObject
@property (nonatomic) uint64_t identifier;
@property (nonatomic) VibeAudioFileMaterializationRole role;
@property (nonatomic) NSTimeInterval submittedAt;
@property (nonatomic, strong) AudioFileMaterializationRequestToken *token;
@end

// Owned apart from the coordinator, which probes do not retain. Counted before
// the worker handoff so quiescence cannot slip through the dispatch gap.
@interface VibeDatalessProbeActivity : NSObject
- (void)beginAttempt;
- (void)finishAttempt;
- (uint64_t)attemptCount;
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
@property (nonatomic) BOOL dataless;
// The run counts against its lane's width. Only a dataless run does, so a
// local read that stalls cannot keep a transfer waiting (releaseLaneForClaim:).
@property (nonatomic) BOOL holdsLane;
@property (nonatomic, strong, nullable) AudioWorkToken *probeToken;
@property (nonatomic) BOOL yieldIfDatalessAfterProbe;
@property (nonatomic, strong, nullable) id<AudioFileMaterializationOperation> operation;
// Set while Running and readable: the transfer goes on, its playback and
// prefetch waiters were served, and its handles read the part file through
// it until the run settles. Its holders are the opens it dispatched and the
// handles they returned.
@property (nonatomic, strong, nullable) CloudFileAvailability *availability;
@end

// The coordinator's state, shared by stage 1 and stage 2.
@interface AudioFileMaterializationCoordinator () {
    // Claim state only; no filesystem or provider I/O on it.
    dispatch_queue_t _stateQueue;
    AudioWorkScheduler *_datalessProbeScheduler;
    VibeDatalessProbeActivity *_datalessProbeActivity;
    dispatch_queue_t _interactiveWorkerQueue;
    dispatch_queue_t _backgroundWorkerQueue;
    dispatch_source_t _pendingTimer;
    NSMutableDictionary<NSString *, VibeAudioFileMaterializationClaim *> *_claims;
    // Stage 2, keyed "purpose:path". Membership is the ceiling's count: a run
    // stays until its AudioFileHandle call returns.
    NSMutableDictionary<NSString *, VibeAudioHandleRun *> *_handleRuns;
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
    // Debug builds only (AudioFileMaterializationCoordinator+Debug.m). Atomic
    // for the health probe's lock-free read; written on the state queue.
    _Atomic uint64_t _handleOpensStarted;
    _Atomic uint64_t _handleOpensCompleted;
    uint64_t _requestsReady;
    uint64_t _requestsFailed;
    uint64_t _requestsYielded;
    uint64_t _requestsAdmissionExhausted;
}

- (void)countSettledRequest:(VibeAudioFileMaterializationResult)result;

@end

@interface AudioFileMaterializationCoordinator (Internal)

- (instancetype)initWithConfiguration:(AudioLoadingConfiguration *)configuration
                      operationFactory:(VibeAudioFileMaterializationOperationFactory)operationFactory
                          datalessProbe:(VibeAudioFileMaterializationDatalessProbe)datalessProbe
                                  clock:(VibeAudioFileMaterializationClock)clock;

- (instancetype)initWithConfiguration:(AudioLoadingConfiguration *)configuration
                      operationFactory:(VibeAudioFileMaterializationOperationFactory)operationFactory
                          datalessProbe:(VibeAudioFileMaterializationDatalessProbe)datalessProbe
                                  clock:(VibeAudioFileMaterializationClock)clock
                            fileOpener:(VibeAudioFileOpener)fileOpener;

// Production stage 1 with an injected stage-2 opener.
- (instancetype)initWithFileOpener:(VibeAudioFileOpener)fileOpener;

// Swappable on a live coordinator; the debug channel reads it back to wrap it.
@property (nonatomic, copy) VibeAudioFileOpener fileOpener;

// Dataless probes outstanding, queued or running, including one whose last
// waiter detached. Lock-free, for quiescence.
- (uint64_t)datalessProbesInFlight;

- (VibeAudioFileMaterializationCoordinatorSnapshot)stateSnapshotForTesting;

@end

// Stage 2's calls from the other files, implemented in
// AudioFileMaterializationCoordinator+HandleOpen.m.
@interface AudioFileMaterializationCoordinator (HandleOpenInternal)

- (void)detachOpenToken:(AudioFileOpenToken *)token;
- (void)notifyDatalessForRun:(VibeAudioHandleRun *)run;
- (void)handleRunTransferSettled:(VibeAudioHandleRun *)run
                    runGeneration:(uint64_t)runGeneration
                           result:(VibeAudioFileMaterializationResult)result
                            error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
