//
//  OpenBurstCoalescer+Debug.h
//  Vibe
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenBurstCoalescer.h"

@interface OpenBurstCoalescer (Debug)
// URLs still waiting behind the quiet period; zero between bursts. Main thread.
- (NSUInteger)debugQueuedURLCount;
@end

#endif
