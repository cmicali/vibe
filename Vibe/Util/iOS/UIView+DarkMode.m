//
//  UIView+DarkMode.m
//  Vibe (iOS)
//

#import "UIView+DarkMode.h"

@implementation UIView (DarkMode)

- (BOOL)isDark {
    return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

@end
