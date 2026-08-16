//
//  OpenRequestCoordinator+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenRequestCoordinator.h"

@interface OpenRequestCoordinator (Debug)
// Results finished but still buffered behind an earlier request, for
// dump_health. It settles back to zero after every burst; a floor that creeps
// upward is a delivery that never happened. Main thread.
- (NSUInteger)debugBufferedResultCount;
@end

#endif
