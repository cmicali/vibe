//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@implementation CoreAudioUtil

OSStatus outputDeviceChangedCallback(AudioObjectID inObjectID,
                                     UInt32 inNumberAddresses,
                                     const AudioObjectPropertyAddress *inAddresses,
                                     void *inClientData) {
    __block id<CoreAudioSystemOutputDeviceDelegate> delegate = (__bridge id<CoreAudioSystemOutputDeviceDelegate>)(inClientData);
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate systemAudioOutputDeviceDidChange];
    });
    return kAudioHardwareNoError;
}

+ (void)listenForSystemOutputDeviceChanges:(id<CoreAudioSystemOutputDeviceDelegate>)delegate {
    CFRunLoopRef nullRunLoop =  NULL;
    AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
    AudioObjectPropertyAddress outputDeviceAddress = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &outputDeviceAddress, &outputDeviceChangedCallback, (__bridge void *)delegate);
}

+ (void) audioOutputDevices {
    AudioObjectPropertyAddress  propertyAddress;
    AudioObjectID               *deviceIDs;
    UInt32                      propertySize;
    NSInteger                   numDevices;

    propertyAddress.mSelector = kAudioHardwarePropertyDevices;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = kAudioObjectPropertyElementMaster;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &propertySize) == noErr) {
        numDevices = propertySize / sizeof(AudioDeviceID);
        deviceIDs = (AudioDeviceID *)calloc(numDevices, sizeof(AudioDeviceID));

        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &propertySize, deviceIDs) == noErr) {
            AudioObjectPropertyAddress      deviceAddress;
            char                            deviceName[64];
            char                            manufacturerName[64];

            for (NSInteger idx=0; idx<numDevices; idx++) {
                propertySize = sizeof(deviceName);
                deviceAddress.mSelector = kAudioDevicePropertyDeviceName;
                deviceAddress.mScope = kAudioObjectPropertyScopeGlobal;
                deviceAddress.mElement = kAudioObjectPropertyElementMaster;
                if (AudioObjectGetPropertyData(deviceIDs[idx], &deviceAddress, 0, NULL, &propertySize, deviceName) == noErr) {
                    propertySize = sizeof(manufacturerName);
                    deviceAddress.mSelector = kAudioDevicePropertyDeviceManufacturer;
                    deviceAddress.mScope = kAudioObjectPropertyScopeGlobal;
                    deviceAddress.mElement = kAudioObjectPropertyElementMaster;
                    if (AudioObjectGetPropertyData(deviceIDs[idx], &deviceAddress, 0, NULL, &propertySize, manufacturerName) == noErr) {
                        CFStringRef     uidString;

                        propertySize = sizeof(uidString);
                        deviceAddress.mSelector = kAudioDevicePropertyDeviceUID;
                        deviceAddress.mScope = kAudioObjectPropertyScopeGlobal;
                        deviceAddress.mElement = kAudioObjectPropertyElementMaster;
                        if (AudioObjectGetPropertyData(deviceIDs[idx], &deviceAddress, 0, NULL, &propertySize, &uidString) == noErr) {
                            LogDebug(@"device %s by %s id %@", deviceName, manufacturerName, uidString);
                            CFRelease(uidString);
                        }
                    }
                }
            }
        }
        free(deviceIDs);
    }
}

+ (AudioDeviceID) audioDeviceIDforUID:(NSString *)uid {
    CFStringRef cs = (__bridge CFStringRef)uid; // CFStringCreateWithCString(0, info.driver, 0); // driver = device's UID
    AudioDeviceID did;
    AudioValueTranslation vt={&cs, sizeof(cs), &did, sizeof(did)};
    UInt32 s = sizeof(vt);
    AudioHardwareGetProperty(kAudioHardwarePropertyDeviceForUID, &s, &vt); // translate device's UID to AudioDeviceID
    CFRelease(cs);
    return did;
}

+ (void) supportedSampleRatesForOutputDevice:(NSString *)uid {
//    BASS_DEVICEINFO info;
//    BASS_GetDeviceInfo(BASS_GetDevice(), &info); // get device info (can use BASS_GetDevice to get current device)
    CFStringRef cs = (__bridge CFStringRef)uid; // CFStringCreateWithCString(0, info.driver, 0); // driver = device's UID
    AudioDeviceID did;
    AudioValueTranslation vt={&cs, sizeof(cs), &did, sizeof(did)};
    UInt32 s = sizeof(vt);
    AudioHardwareGetProperty(kAudioHardwarePropertyDeviceForUID, &s, &vt); // translate device's UID to AudioDeviceID
    CFRelease(cs);
    AudioObjectPropertyAddress pa={kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    AudioObjectGetPropertyDataSize(did, &pa, 0, NULL, &s); // get size of available sample rates array
    // AudioValueRange *vr= new AudioValueRange[s/sizeof(AudioValueRange)]; // allocate it
    AudioValueRange vr[512];
    AudioObjectGetPropertyData(did, &pa, 0, NULL, &s, vr); // get the available sample rates
    for (int a=0; a<s/sizeof(AudioValueRange); a++)
        printf("%g - %g\n", vr[a].mMinimum, vr[a].mMaximum);
}


- (Float64)getCurrentSampleRateForOutputDevice:(NSString *)uid {
//    BASS_DEVICEINFO info;
//    BASS_GetDeviceInfo(BASS_GetDevice(), &info); // get device info
    CFStringRef cs = (__bridge CFStringRef)uid;
    AudioDeviceID did;
    AudioValueTranslation vt={&cs, sizeof(cs), &did, sizeof(did)};
    UInt32 s=sizeof(vt);
    AudioHardwareGetProperty(kAudioHardwarePropertyDeviceForUID, &s, &vt); // translate device's UID to AudioDeviceID
    CFRelease(cs);
    AudioStreamBasicDescription sbd;
    s=sizeof(sbd);
    if (!AudioDeviceGetProperty(did, 0, false, kAudioDevicePropertyStreamFormat, &s, &sbd)) { // get current format
        return sbd.mSampleRate;
    }
    return -1;
}

+ (Float64)setSampleRate:(int)rate forDeviceUID:(NSString *)uid {
    CFStringRef cs = (__bridge CFStringRef)uid; // CFStringCreateWithCString(0, info.driver, 0); // driver = device's UID
    AudioDeviceID did;
    AudioValueTranslation vt={&cs, sizeof(cs), &did, sizeof(did)};
    UInt32 s=sizeof(vt);
    AudioHardwareGetProperty(kAudioHardwarePropertyDeviceForUID, &s, &vt); // translate device's UID to AudioDeviceID
    CFRelease(cs);
    AudioStreamBasicDescription sbd;
    s=sizeof(sbd);
    if (!AudioDeviceGetProperty(did, 0, false, kAudioDevicePropertyStreamFormat, &s, &sbd)) { // get current format
        sbd.mSampleRate=rate; // change rate
        AudioDeviceSetProperty(did, NULL, 0, false, kAudioDevicePropertyStreamFormat, s, &sbd); // try to apply change
    }
    if (!AudioDeviceGetProperty(did, 0, false, kAudioDevicePropertyStreamFormat, &s, &sbd)) { // get current format
        return sbd.mSampleRate;
    }
    return -1;
}


@end
