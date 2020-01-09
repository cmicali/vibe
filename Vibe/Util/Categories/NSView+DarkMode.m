//
// Created by Christopher Micali on 1/9/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "NSView+DarkMode.h"

@implementation NSView (DarkMode)

- (BOOL)isDark {
    return [NSAppearanceNameDarkAqua isEqualToString:[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]];
}

@end
