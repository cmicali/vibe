//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "AudioDevice.h"

@interface AudioDeviceManager : NSObject

+ (AudioDeviceManager *)sharedInstance;

- (NSInteger)numOutputDevices;

- (NSArray<AudioDevice *> *)outputDevices;

- (AudioDevice *)outputDeviceForName:(NSString *)name;
- (AudioDevice *)outputDeviceForUID:(NSString *)uid;
- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId;

// kAudioObjectUnknown when there is no default output device.
+ (AudioDeviceID)systemDefaultOutputDeviceID;
+ (NSString *)uidForDeviceID:(AudioDeviceID)deviceID;

@end
