//
//  VibeWeakProxy.h
//  Vibe
//
//  CADisplayLink retains its target; a weak proxy keeps the real target's
//  dealloc (and the invalidate in it) reachable. Messages to a dead target
//  no-op.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeWeakProxy : NSProxy

+ (instancetype)proxyWithTarget:(id)target;

@end

NS_ASSUME_NONNULL_END
