//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>

@implementation CoreAudioUtil

// Unretained delegate pointer for the default-output-device listener. The
// caller must call stopListeningForSystemOutputDeviceChanges before the
// delegate deallocates (retaining here would keep the delegate alive forever
// and prevent its dealloc from ever running).
static void *gOutputDeviceListenerClientData = NULL;

static const AudioObjectPropertyAddress kOutputDeviceAddress = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

OSStatus outputDeviceChangedCallback(AudioObjectID inObjectID,
                                     UInt32 inNumberAddresses,
                                     const AudioObjectPropertyAddress *inAddresses,
                                     void *inClientData) {
    // Strong local capture so the block on the main queue holds its own retain
    // while it is queued/running (the client-data pointer itself is unretained).
    id<CoreAudioSystemOutputDeviceDelegate> delegate = (__bridge id<CoreAudioSystemOutputDeviceDelegate>)(inClientData);
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate systemAudioOutputDeviceDidChange];
    });
    return kAudioHardwareNoError;
}

+ (void)listenForSystemOutputDeviceChanges:(id<CoreAudioSystemOutputDeviceDelegate>)delegate {
    [self stopListeningForSystemOutputDeviceChanges];
    CFRunLoopRef nullRunLoop =  NULL;
    AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
    gOutputDeviceListenerClientData = (__bridge void *)delegate;
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kOutputDeviceAddress, &outputDeviceChangedCallback, gOutputDeviceListenerClientData);
}

+ (void)stopListeningForSystemOutputDeviceChanges {
    if (!gOutputDeviceListenerClientData) {
        return;
    }
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kOutputDeviceAddress, &outputDeviceChangedCallback, gOutputDeviceListenerClientData);
    gOutputDeviceListenerClientData = NULL;
}

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

+ (NSMutableArray<NSNumber *>*) supportedSampleRatesForAudioDeviceId:(AudioDeviceID)did {
    NSMutableArray *result = [[NSMutableArray alloc] init];
    if (did == kAudioObjectUnknown) {
        return result;
    }
    UInt32 s = 0;
    AudioObjectPropertyAddress pa={kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(did, &pa, 0, NULL, &s) != noErr || s == 0) { // get size of available sample rates array
        return result;
    }
    AudioValueRange *vr = new AudioValueRange[s/sizeof(AudioValueRange)]; // allocate it
    if (AudioObjectGetPropertyData(did, &pa, 0, NULL, &s, vr) != noErr) { // get the available sample rates
        delete [] vr;
        return result;
    }
    NSUInteger count = s / sizeof(AudioValueRange);
    for (int i = 0; i < count; i++)
        [result addObject:@(vr[i].mMinimum)];
    delete [] vr;
    return result;
}

+ (NSArray<NSNumber *>*) supportedSampleRatesForOutputDevice:(NSString *)uid {
    return [self supportedSampleRatesForAudioDeviceId:[self audioDeviceIDforUID:uid]];
}


+ (Float64)getCurrentSampleRateForOutputDevice:(NSString *)uid {
    AudioDeviceID did = [self audioDeviceIDforUID:uid];
    AudioStreamBasicDescription mFormat;
    UInt32 size = sizeof(mFormat);
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, 0 };
    if (AudioObjectGetPropertyData(did, &addr, 0, NULL, &size, &mFormat) == noErr) {
        return mFormat.mSampleRate;
    }
    return -1;
}

+ (BOOL)setSampleRate:(double)rate forAudioDeviceID:(AudioDeviceID)did {
    AudioStreamBasicDescription mFormat;
    UInt32 size = sizeof(mFormat);

    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, 0 };
    OSStatus err = AudioObjectGetPropertyData(did, &addr, 0, NULL, &size, &mFormat);
    LogDebug(@"CoreAudioUtil: setSampleRate: %.0f -> %0.1f", mFormat.mSampleRate, rate);
    mFormat.mSampleRate = rate;
    mFormat.mBitsPerChannel = 32 ;
    addr = { kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeGlobal, 0 };
    err = AudioObjectSetPropertyData(did, &addr, 0, NULL, size, &mFormat);
    return err == noErr;
}

+ (BOOL)setBestSampleRate:(double)rate forDeviceUID:(NSString *)uid {
    AudioDeviceID did = [self audioDeviceIDforUID:uid];
    NSArray<NSNumber *> *rates = [self supportedSampleRatesForAudioDeviceId:did];
    if (![rates containsObject:@(rate)]) {
        rates = [rates sortedArrayUsingComparator:^NSComparisonResult(NSNumber* n1, NSNumber* n2) {
            return [n1 compare:n2];
        }];
        LogError(@"CoreAudioUtil: setSampleRate: requested rate %.0f not in [%@]", rate, [rates componentsJoinedByString:@", "]);
        double candidateRate = rate;
        double minRate = 44100;
        for (NSNumber *number in rates) {
            double n = [number doubleValue];
            if (n >= minRate && n >= candidateRate) {
                candidateRate = n;
                break;
            }
        }
        if (candidateRate == rate) {
            LogError(@"could not find better rate");
            return NO;
        }
        rate = candidateRate;
    }
    return [self setSampleRate:rate forAudioDeviceID:did];
}

@end
