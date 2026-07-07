//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioDeviceManager.h"
#import "AudioDevice.h"

@implementation AudioDeviceManager

+ (AudioDeviceManager*)sharedInstance {
    static AudioDeviceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioDeviceManager alloc] init];
    });
    return instance;
}

+ (AudioDeviceID)systemDefaultOutputDeviceID {
    AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (status != noErr) {
        return kAudioObjectUnknown;
    }
    return deviceID;
}

+ (NSString *)uidForDeviceID:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return nil;
    }
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &uid);
    if (status != noErr || !uid) {
        return nil;
    }
    return CFBridgingRelease(uid);
}

+ (NSString *)nameForDeviceID:(AudioDeviceID)deviceID {
    AudioObjectPropertyAddress addr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &name);
    if (status != noErr || !name) {
        return nil;
    }
    return CFBridgingRelease(name);
}

+ (BOOL)deviceHasOutputChannels:(AudioDeviceID)deviceID {
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size) != noErr || size == 0) {
        return NO;
    }
    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return NO;
    }
    BOOL hasOutput = NO;
    if (AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList) == noErr) {
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            if (bufferList->mBuffers[i].mNumberChannels > 0) {
                hasOutput = YES;
                break;
            }
        }
    }
    free(bufferList);
    return hasOutput;
}

- (NSArray<AudioDevice *>*)outputDevices {
    AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || size == 0) {
        return @[];
    }
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(size);
    if (!deviceIDs) {
        return @[];
    }
    NSMutableArray *result = [[NSMutableArray alloc] init];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, deviceIDs) == noErr) {
        // size is in/out: recompute from what was actually returned so a
        // device vanishing mid-query can't make us read the buffer tail.
        UInt32 count = size / sizeof(AudioDeviceID);
        AudioDeviceID defaultID = [AudioDeviceManager systemDefaultOutputDeviceID];
        for (UInt32 i = 0; i < count; i++) {
            if (![AudioDeviceManager deviceHasOutputChannels:deviceIDs[i]]) {
                continue;
            }
            AudioDevice *device = [AudioDeviceManager deviceForID:deviceIDs[i] defaultID:defaultID];
            if (device) {
                [result addObject:device];
            }
        }
    }
    free(deviceIDs);
    return result;
}

+ (AudioDevice *)deviceForID:(AudioDeviceID)deviceID defaultID:(AudioDeviceID)defaultID {
    NSString *name = [AudioDeviceManager nameForDeviceID:deviceID];
    if (!name.length) {
        return nil;
    }
    AudioDevice *device = [[AudioDevice alloc] init];
    device.name = name;
    device.uid = [AudioDeviceManager uidForDeviceID:deviceID] ?: @"default";
    device.deviceId = (NSInteger)deviceID;
    device.isSystemDefault = (deviceID == defaultID);
    return device;
}

- (NSInteger)numOutputDevices {
    return (NSInteger)self.outputDevices.count;
}

- (AudioDevice *)outputDeviceForName:(NSString *)name {
    if (name.length == 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if ([device.name isEqualToString:name]) {
            return device;
        }
    }
    return nil;
}

- (AudioDevice *)outputDeviceForUID:(NSString *)uid {
    if (uid.length == 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if ([device.uid isEqualToString:uid]) {
            return device;
        }
    }
    return nil;
}

- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId {
    if (deviceId < 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if (device.deviceId == deviceId) {
            return device;
        }
    }
    return nil;
}

@end
