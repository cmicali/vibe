//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioDevice.h"


@implementation AudioDevice

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[AudioDevice class]]) return NO;
    return self.deviceId == ((AudioDevice *)object).deviceId;
}

- (NSUInteger)hash {
    return (NSUInteger)self.deviceId;
}

@end
