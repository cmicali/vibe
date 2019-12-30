//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "Fonts.h"

@implementation Fonts {

}

+ (NSFont *)fontForNumbers:(CGFloat)size {
    return [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
}

@end
