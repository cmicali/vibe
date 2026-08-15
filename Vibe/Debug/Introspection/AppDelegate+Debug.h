//
//  AppDelegate+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
//

#if DEBUG

#import "AppDelegate.h"

@interface AppDelegate (Debug)
// The burst coalescer's queue depth for dump_health. Forwarded rather than
// exposing the coalescer, which is a private ivar there.
- (NSUInteger)debugQueuedOpenCount;
@end

#endif
