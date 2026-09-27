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

// The fast path, every frame; only a dead target reaches the invocation path.
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
