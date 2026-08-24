//
//  AudioFileMaterializationCoordinatorInternal.h
//  Vibe
//

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioFileMaterializationOperation <NSObject>

// Background only. cancel must return immediately and may be called before or
// during runWithError:.
- (BOOL)runWithError:(NSError *__autoreleasing _Nullable *_Nullable)error;
- (void)cancel;

@end

typedef id<AudioFileMaterializationOperation> _Nonnull
        (^VibeAudioFileMaterializationOperationFactory)(
                NSURL *url, VibeAudioFileMaterializationRole role);
typedef NSTimeInterval (^VibeAudioFileMaterializationClock)(void);
// YES when the file's contents are not local, so materializing it means a
// provider transfer. Production is NSURLUtil.isDatalessFile:. Called
// concurrently on bounded workers, may block, and must be thread-safe. An
// initial NO answer bypasses transfer admission. A refresh runs only after its
// lane is reserved; NO suppresses transfer publication, but that run returns
// the lane only when its operation settles.
typedef BOOL (^VibeAudioFileMaterializationDatalessProbe)(NSURL *url);
// Stage 2's injected seam: the one AVAudioFile call, host-lessly replaceable.
typedef AVAudioFile * _Nullable (^VibeAudioFileOpener)(
        NSURL *url, NSError * _Nullable __autoreleasing * _Nullable error);

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
    // Cumulative for the life of the coordinator. The gauges above cannot tell
    // "nothing is happening" from "a great deal is happening quickly", which is
    // exactly what a silent stall looks like; these can. handleOpensStarted
    // minus handleOpensCompleted is the number of uncancellable AVAudioFile
    // calls outstanding, and must be zero at rest.
    uint64_t handleOpensStarted;
    uint64_t handleOpensCompleted;
    uint64_t requestsReady;
    uint64_t requestsFailed;
    uint64_t requestsYielded;
    uint64_t requestsAdmissionExhausted;
} VibeAudioFileMaterializationCoordinatorSnapshot;

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

// Production stage-1 (real materializer, real probe, real clock) with an
// injected stage-2 opener: the gated-opener tests' seam.
- (instancetype)initWithFileOpener:(VibeAudioFileOpener)fileOpener;

// Stage 2's opener, swappable on a live coordinator so the debug channel can
// wrap it. Reading it back is how a wrapper chains to the real one rather than
// restating what a production open is.
@property (nonatomic, copy) VibeAudioFileOpener fileOpener;

// Stranded AVAudioFile calls, readable from any thread without taking the
// state queue. The health probe polls this; nothing else should need it.
- (uint64_t)handleOpensInFlight;

// Dataless classification attempts outstanding from scheduler/worker handoff
// through cancellation, rejection, or state settlement. This includes queued
// initial work and a running call whose last waiter detached. Lock-free for
// quiescence.
- (uint64_t)datalessProbesInFlight;

- (VibeAudioFileMaterializationCoordinatorSnapshot)stateSnapshotForTesting;
- (void)expirePendingClaimsForTesting;

@end

NS_ASSUME_NONNULL_END
