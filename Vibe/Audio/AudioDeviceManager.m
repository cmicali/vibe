//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioDeviceManager.h"
#import "BassWrapper.h"
#import "AudioDevice.h"

@implementation AudioDeviceManager {

}

+ (AudioDeviceManager*)sharedInstance {
    static AudioDeviceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioDeviceManager alloc] init];
    });
    return instance;
}

- (NSInteger)numOutputDevices {
    int a, count = 0;
    BASS_DEVICEINFO info;
    for (a = 1; BASS_GetDeviceInfo(a, &info); a++)
        if (info.flags & BASS_DEVICE_ENABLED)
            count++; // count it
    return count;
}

- (AudioDevice *)outputDeviceForId:(NSInteger)id {
    AudioDevice *dev = [[AudioDevice alloc] init];
    if (id == -1) {
        dev.name = @"System Default";
        dev.id = id;
        return dev;
    }
    else {
        BASS_DEVICEINFO info;
        if (!BASS_GetDeviceInfo((DWORD)(id + 1), &info)) {
            return nil;
        }
        dev.name = [NSString stringWithCString:info.name encoding:NSUTF8StringEncoding];
        dev.id = id;
        dev.isSystemDefault = (BOOL) (info.flags & BASS_DEVICE_DEFAULT);
    }
    return dev;
}

@end
