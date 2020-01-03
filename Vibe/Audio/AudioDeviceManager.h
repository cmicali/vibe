//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioDevice.h"

@interface AudioDeviceManager : NSObject

+ (AudioDeviceManager *)sharedInstance;

- (AudioDevice *)defaultOutputDevice;

- (NSInteger)defaultOutputDeviceId;

- (NSInteger)numOutputDevices;

- (NSArray<AudioDevice *> *)outputDevices;

- (AudioDevice *)outputDeviceForName:(NSString *)name;
- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId;

@end
