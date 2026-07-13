//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>

@implementation CoreAudioUtil

+ (AudioDeviceID) audioDeviceIDforUID:(NSString *)deviceUid {
    CFStringRef uid = (__bridge CFStringRef)deviceUid;

    AudioObjectPropertyAddress property_address = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    AudioDeviceID audio_device_id = kAudioObjectUnknown;
    UInt32 device_size = sizeof(audio_device_id);
    OSStatus result = -1;

    AudioValueTranslation value;
    value.mInputData = &uid;
    value.mInputDataSize = sizeof(CFStringRef);
    value.mOutputData = &audio_device_id;
    value.mOutputDataSize = device_size;
    UInt32 translation_size = sizeof(AudioValueTranslation);

    property_address.mSelector = kAudioHardwarePropertyDeviceForUID;
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject,
            &property_address,
            0,
            0,
            &translation_size,
            &value);

    return audio_device_id;
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

@end
