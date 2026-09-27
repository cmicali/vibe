//
//  OpenRequestCoordinator+Debug.h
//  Vibe
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenRequestCoordinator.h"

@interface OpenRequestCoordinator (Debug)
// Results finished but buffered behind an earlier request. Zero after every
// burst; a floor that creeps upward is a delivery that never happened. Main
// thread.
- (NSUInteger)debugBufferedResultCount;
@end

#endif
