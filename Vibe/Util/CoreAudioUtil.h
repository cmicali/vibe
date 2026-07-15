//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

// Raw HAL property accessors (one property read/write per method). Device
// enumeration, AudioDevice model lookup, and device-change notifications
// live in AudioDeviceManager.
@interface CoreAudioUtil : NSObject

// kAudioObjectUnknown when there is no default.
+ (AudioDeviceID)systemDefaultOutputDeviceID;

// nil when the device is gone or has no such property.
+ (NSString *)uidForDeviceID:(AudioDeviceID)deviceID;
+ (NSString *)nameForDeviceID:(AudioDeviceID)deviceID;

+ (BOOL)deviceHasOutputChannels:(AudioDeviceID)deviceID;

@end
