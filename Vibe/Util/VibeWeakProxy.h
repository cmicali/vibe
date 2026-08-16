//
//  VibeWeakProxy.h
//  Vibe
//
//  CADisplayLink retains its target for the link's lifetime; aiming it
//  through a weak proxy keeps the real target's dealloc reachable, so an
//  invalidate there is real rather than aspirational. Once the target dies,
//  forwarded invocations no-op.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeWeakProxy : NSProxy

+ (instancetype)proxyWithTarget:(id)target;

@end

NS_ASSUME_NONNULL_END
