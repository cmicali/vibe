//
//  UIImage+DominantColor.m
//  Vibe (iOS)
//

#import "UIImage+DominantColor.h"

#import <objc/runtime.h>

#import "PlatformImage.h"

@implementation UIImage (VibeDominantColor)

- (UIColor *)vibeDominantColor {
    id memoized = objc_getAssociatedObject(self, _cmd);
    if (memoized) {
        return memoized == NSNull.null ? nil : memoized;
    }
    UIColor *color = VibeDominantColorOfImage(self);
    objc_setAssociatedObject(self, _cmd, color ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return color;
}

@end
