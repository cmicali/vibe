//
//  VibeWeakProxy.m
//  Vibe (iOS)
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

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_target methodSignatureForSelector:selector]
            ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_target]; // nil target: the invocation no-ops
}

@end
