//
//  NSView+DarkMode.m
//  Vibe
//

#import "NSView+DarkMode.h"

@implementation NSView (DarkMode)

- (BOOL)isDark {
    return [NSAppearanceNameDarkAqua isEqualToString:[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]];
}

@end
