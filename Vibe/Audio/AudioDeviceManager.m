//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioDeviceManager.h"
#import "BassWrapper.h"
#import "AudioDevice.h"

@implementation AudioDeviceManager {
    AudioDevice* _defaultOutputDevice;
}

+ (AudioDeviceManager*)sharedInstance {
    static AudioDeviceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioDeviceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaultOutputDevice = [[AudioDevice alloc] init];
        _defaultOutputDevice.name = @"System Default";
        _defaultOutputDevice.deviceId = -1;
    }
    return self;
}

- (AudioDevice *)defaultOutputDevice {
    return _defaultOutputDevice;
}

- (NSInteger)numOutputDevices {
    int a, count = 0;
    BASS_DEVICEINFO info;
    for (a = 1; BASS_GetDeviceInfo((DWORD)a, &info); a++)
        if (info.flags & BASS_DEVICE_ENABLED)
            count++; // count it
    return count;
}

- (NSArray<AudioDevice *>*)outputDevices {
    BASS_DEVICEINFO info;
    NSMutableArray *result = [[NSMutableArray alloc] init];
    for (int a = 1; BASS_GetDeviceInfo((DWORD)a, &info); a++)
        if (info.flags & BASS_DEVICE_ENABLED)
            [result addObject:[self outputDeviceForId:a]];
    return result;
}

- (AudioDevice *)outputDeviceForName:(NSString *)name {
    NSInteger deviceId = -1;
    if (name.length > 0) {
        const char *requestedName = [name cStringUsingEncoding:NSUTF8StringEncoding];
        BASS_DEVICEINFO info;
        for (int i = 1; BASS_GetDeviceInfo((DWORD)i, &info); i++) {
            if (info.flags & BASS_DEVICE_ENABLED) {
                if (strncmp(info.name, requestedName, name.length) == 0) {
                    deviceId = i;
                    break;
                }
            }
        }
    }
    return [self outputDeviceForId:deviceId];
}

- (AudioDevice *)outputDeviceWithDeviceInfo:(BASS_DEVICEINFO *)info deviceId:(NSInteger)deviceId {
    AudioDevice *dev = [[AudioDevice alloc] init];
    dev.name = [NSString stringWithCString:info->name encoding:NSUTF8StringEncoding];
    dev.uid = [NSString stringWithCString:info->driver encoding:NSUTF8StringEncoding];
    dev.deviceId = deviceId;
    dev.isSystemDefault = (info->flags & BASS_DEVICE_DEFAULT) != 0;
    return dev;
}

- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId {
    if (deviceId == -1) {
        return _defaultOutputDevice;
    }
    BASS_DEVICEINFO info;
    if (!BASS_GetDeviceInfo((DWORD)deviceId, &info)) {
        return nil;
    }
    return [self outputDeviceWithDeviceInfo:&info deviceId:deviceId];
}

@end
