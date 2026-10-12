//
//  AudioFileMaterializationCoordinator+Debug.h
//  Vibe
//
//  The path-wide admission counters and the stage-2 open hang. Both
//  categories are implemented in AudioFileMaterializationCoordinator+Debug.m.
//

#if DEBUG

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileMaterializationCoordinator (Debug)
- (NSDictionary<NSString *, NSNumber *> *)debugState;

// Wedges stage 2, the handle open after materialization: opens of `basename`
// block inside the AudioFileHandle call, deaf to a cancel as a whole-file open
// is, until released. The fake cloud cannot stage this, since under it the
// bytes are local and a real open never blocks. nil also releases the opens
// already held.
+ (void)debugHangOpensForBasename:(nullable NSString *)basename;
+ (void)debugReleaseHungOpens;
+ (NSUInteger)debugHungOpenCount;
@end

// The counters it reads are in AudioFileMaterializationCoordinatorInternal.h.
@interface AudioFileMaterializationCoordinator (DebugCounters)
// Outstanding AudioFileHandle calls, lock-free, for the health probe. Never
// overstates; a racing open may read low.
- (uint64_t)handleOpensInFlight;
// Stage 2's two edges of that count, on the state queue
// (AudioFileMaterializationCoordinator+HandleOpen.m).
- (void)countHandleOpenStarted;
- (void)countHandleOpenCompleted;
@end

NS_ASSUME_NONNULL_END

#endif
