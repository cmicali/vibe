//
//  OpenBurstCoalescer+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenBurstCoalescer.h"

@interface OpenBurstCoalescer (Debug)
// URLs still waiting behind the quiet period, for dump_health. Zero between
// bursts. Main thread.
- (NSUInteger)debugQueuedURLCount;
@end

#endif
