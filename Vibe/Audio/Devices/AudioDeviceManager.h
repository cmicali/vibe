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

// Snapshot of the current output devices, served from a cache the HAL
// listeners keep fresh (refreshed on a background queue BEFORE observers are
// notified, so a change callback reads the post-change list). Cheap on the
// main thread after first use — no per-call HAL enumeration. The first-ever
// call waits for asynchronous listener setup and its post-registration sweep,
// unbounded off the main thread and briefly bounded on it; keep it off the
// launch main path either way.
- (NSArray<AudioDevice *> *)outputDevices;

- (AudioDevice *)outputDeviceForName:(NSString *)name;
- (AudioDevice *)outputDeviceForUID:(NSString *)uid;
- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId;

@end
