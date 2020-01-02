//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AudioDevice;


@interface AudioDeviceManager : NSObject

+ (AudioDeviceManager *)sharedInstance;

- (NSInteger)numOutputDevices;
- (AudioDevice *)outputDeviceForId:(NSInteger)id;

@end
