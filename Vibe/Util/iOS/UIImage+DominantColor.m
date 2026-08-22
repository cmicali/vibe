//
//  UIImage+DominantColor.m
//  Vibe (iOS)
//
//  See UIImage+DominantColor.h.
//

#import "UIImage+DominantColor.h"

#import <objc/runtime.h>

#import "PlatformImage.h"

@implementation UIImage (VibeDominantColor)

- (UIColor *)vibeDominantColor {
    UIColor *memoized = objc_getAssociatedObject(self, _cmd);
    if (memoized) {
        return memoized;
    }
    UIColor *color = VibeDominantColorOfImage(self);
    if (color) {
        objc_setAssociatedObject(self, _cmd, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return color;
}

@end
