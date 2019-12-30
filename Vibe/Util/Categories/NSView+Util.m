//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSView+Util.h"

@implementation NSView (Util)

- (NSView*) viewWithIdentifier:(NSString *)identifier {
    for (NSView* subview in self.subviews) {
        if ([subview.identifier isEqualToString:identifier]) {
            return subview;
        }
    }
    return nil;
}

@end
