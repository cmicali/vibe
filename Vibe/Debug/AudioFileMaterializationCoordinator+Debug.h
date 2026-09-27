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

NS_ASSUME_NONNULL_END

#endif
