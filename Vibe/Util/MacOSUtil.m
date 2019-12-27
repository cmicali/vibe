//
// Created by Christopher Micali on 12/27/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MacOSUtil.h"

@implementation MacOSUtil {

}

+ (BOOL)isDarkMode:(NSAppearance * )appearance {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName basicAppearance = [appearance bestMatchFromAppearancesWithNames:@[
                NSAppearanceNameAqua,
                NSAppearanceNameDarkAqua
        ]];
        return [basicAppearance isEqualToString:NSAppearanceNameDarkAqua];
    } else {
        return NO;
    }
}

@end
