//
//  AudioFileMaterializationCoordinator+Debug.h
//  Vibe
//
//  Debug-only declaration for the path-wide admission counters.
//

#if DEBUG

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileMaterializationCoordinator (Debug)
- (NSDictionary<NSString *, NSNumber *> *)debugState;

// Wedges stage 2, the handle open after materialization: opens of `basename`
// block inside the uncancellable AudioFileHandle call until released. The fake
// cloud cannot stage this, since under it the bytes are local and a real open
// never blocks. nil also releases the opens already held.
+ (void)debugHangOpensForBasename:(nullable NSString *)basename;
+ (void)debugReleaseHungOpens;
+ (NSUInteger)debugHungOpenCount;
@end

// Implemented in AudioFileMaterializationCoordinator.m, beside the counters it
// reads.
@interface AudioFileMaterializationCoordinator (DebugCounters)
// Outstanding AudioFileHandle calls, lock-free, for the health probe. Never
// overstates; a racing open may read low.
- (uint64_t)handleOpensInFlight;
@end

NS_ASSUME_NONNULL_END

#endif
