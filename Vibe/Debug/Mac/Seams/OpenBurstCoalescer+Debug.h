//
//  OpenBurstCoalescer+Debug.h
//  Vibe
//
//  Implemented beside the coalescer, whose queue is private to it.
//

#import "OpenBurstCoalescer.h"

NS_ASSUME_NONNULL_BEGIN

@interface OpenBurstCoalescer (Debug)
// URLs still waiting behind the quiet period; zero between bursts. Main thread.
- (NSUInteger)debugQueuedURLCount;
@end

NS_ASSUME_NONNULL_END
