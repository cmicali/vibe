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
// an operation that cannot stream never calls it. probedLocal says the probe
// found the contents local just before this run, so it need not look again.
- (BOOL)runOnReadable:(dispatch_block_t)onReadable
          probedLocal:(BOOL)probedLocal
                error:(NSError *__autoreleasing _Nullable *_Nullable)error;
- (void)cancel;

@end

typedef id<AudioFileMaterializationOperation> _Nonnull
        (^VibeAudioFileMaterializationOperationFactory)(
                NSURL *url, VibeAudioFileMaterializationRole role);
typedef NSTimeInterval (^VibeAudioFileMaterializationClock)(void);
// YES when the contents are not local (production: NSURLUtil.isDatalessFile:).
// Called concurrently on bounded workers; may block. An initial NO bypasses
// transfer admission; a refresh's NO suppresses publication but keeps its
// reserved lane until the operation settles.
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

NS_ASSUME_NONNULL_END
