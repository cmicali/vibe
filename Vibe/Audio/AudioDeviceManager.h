//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "AudioDevice.h"

// Callbacks are delivered on the main thread in the common run-loop modes, so
// they also fire while a menu is tracking (letting an open devices menu
// refresh on hotplug).
@protocol AudioDeviceManagerObserver <NSObject>
@optional
- (void)systemDefaultOutputDeviceDidChange;
- (void)audioOutputDevicesDidChange;
@end

@interface AudioDeviceManager : NSObject

+ (AudioDeviceManager *)sharedInstance;

// Observers are held weakly; add/remove may be called from any thread.
- (void)addObserver:(id<AudioDeviceManagerObserver>)observer;
- (void)removeObserver:(id<AudioDeviceManagerObserver>)observer;

- (NSInteger)numOutputDevices;

- (NSArray<AudioDevice *> *)outputDevices;

- (AudioDevice *)outputDeviceForName:(NSString *)name;
- (AudioDevice *)outputDeviceForUID:(NSString *)uid;
- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId;

@end
