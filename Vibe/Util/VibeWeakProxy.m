//
//  VibeWeakProxy.m
//  Vibe
//

#import "VibeWeakProxy.h"

@implementation VibeWeakProxy {
    __weak id _target;
}

+ (instancetype)proxyWithTarget:(id)target {
    VibeWeakProxy *proxy = [self alloc];
    proxy->_target = target;
    return proxy;
}

// The fast path: the runtime re-sends the message to the target directly. A
// display link fires through here every frame, and the invocation path below
// cost a method-signature lookup and an NSInvocation per tick. Only a dead
// target falls through to it.
- (id)forwardingTargetForSelector:(SEL)selector {
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_target methodSignatureForSelector:selector]
            ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_target]; // nil target: the invocation no-ops
}

@end
