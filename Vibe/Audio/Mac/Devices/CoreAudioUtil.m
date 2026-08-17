//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>

@implementation CoreAudioUtil

+ (AudioDeviceID)systemDefaultOutputDeviceID {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    [self readSystemDefaultOutputDeviceID:&deviceID];
    return deviceID;
}

+ (BOOL)readSystemDefaultOutputDeviceID:(AudioDeviceID *)deviceID {
    if (!deviceID) {
        return NO;
    }
    *deviceID = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*deviceID);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject,
            &addr, 0, NULL, &size, deviceID) == noErr;
}

+ (BOOL)readUID:(NSString **)uid forDeviceID:(AudioDeviceID)deviceID {
    if (!uid) {
        return NO;
    }
    *uid = nil;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    // A few virtual devices expose no UID at all. That is a complete read with
    // an absent optional value, not a reason to discard the whole snapshot.
    if (!AudioObjectHasProperty(deviceID, &addr)) {
        return YES;
    }
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &value);
    if (status != noErr || !value) {
        if (value) {
            CFRelease(value);
        }
        return NO;
    }
    *uid = CFBridgingRelease(value);
    return YES;
}

+ (BOOL)readName:(NSString **)name forDeviceID:(AudioDeviceID)deviceID {
    if (!name) {
        return NO;
    }
    *name = nil;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceID, &addr)) {
        return NO;
    }
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &value);
    if (status != noErr || !value) {
        if (value) {
            CFRelease(value);
        }
        return NO;
    }
    NSString *readName = CFBridgingRelease(value);
    if (readName.length == 0) {
        return NO;
    }
    *name = readName;
    return YES;
}

+ (BOOL)readHasOutputChannels:(BOOL *)hasOutputChannels
                  forDeviceID:(AudioDeviceID)deviceID {
    if (!hasOutputChannels) {
        return NO;
    }
    *hasOutputChannels = NO;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceID, &addr)) {
        return NO;
    }
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size) != noErr) {
        return NO;
    }
    if (size == 0) {
        return YES;
    }
    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return NO;
    }
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList);
    if (status == noErr) {
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            if (bufferList->mBuffers[i].mNumberChannels > 0) {
                *hasOutputChannels = YES;
                break;
            }
        }
    }
    free(bufferList);
    return status == noErr;
}

@end
