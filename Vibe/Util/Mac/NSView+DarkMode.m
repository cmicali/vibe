//
//  NSView+DarkMode.m
//  Vibe
//

#import "NSView+DarkMode.h"

@implementation NSAppearance (DarkMode)

- (BOOL)isDark {
    return [NSAppearanceNameDarkAqua isEqualToString:
            [self bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,
                                                      NSAppearanceNameDarkAqua]]];
}

@end

@implementation NSView (DarkMode)

- (BOOL)isDark {
    return self.effectiveAppearance.isDark;
}

@end
