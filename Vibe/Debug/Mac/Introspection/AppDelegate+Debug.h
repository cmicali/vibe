//
//  AppDelegate+Debug.h
//  Vibe
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "AppDelegate.h"

@interface AppDelegate (Debug)
// The burst coalescer's queue depth, forwarded so the coalescer stays a
// private ivar.
- (NSUInteger)debugQueuedOpenCount;
@end

#endif
