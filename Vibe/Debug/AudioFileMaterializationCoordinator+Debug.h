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
@end

NS_ASSUME_NONNULL_END

#endif
