//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioDevice.h"


@implementation AudioDevice

- (BOOL)isEqual:(AudioDevice*)object {
    return self.id == object.id;
}

- (NSUInteger)hash {
    return [[NSString stringWithFormat:@"%ld", (long)self.id] hash];
}

@end
