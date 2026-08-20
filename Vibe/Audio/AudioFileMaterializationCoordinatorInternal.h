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
// provider transfer. Production is NSURLUtil.isDatalessFile:. Lane capacity,
// the admission grace, and the foreground rule all bound *transfers*, so a NO
// answer exempts a claim from every one of them.
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
    BOOL foregroundTransferActive;
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

- (VibeAudioFileMaterializationCoordinatorSnapshot)stateSnapshotForTesting;
- (void)expirePendingClaimsForTesting;

@end

NS_ASSUME_NONNULL_END
