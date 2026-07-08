//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>

// Trampoline between the HAL listener callback and the real delegate. It is
// retained by the static reference below (so the callback's client-data pointer
// is always to a live object) and holds only a *weak* reference to the delegate
// — a HAL-thread callback firing during the delegate's dealloc reads nil and
// no-ops instead of resurrecting/messaging a deallocating object.
@interface VibeOutputDeviceListenerTrampoline : NSObject
@property (weak) id<CoreAudioSystemOutputDeviceDelegate> delegate;
@end

@implementation VibeOutputDeviceListenerTrampoline
@end

@implementation CoreAudioUtil

// Retained trampoline for the default-output-device listener (nil when not
// listening). Its lifetime brackets Add/RemovePropertyListener.
static VibeOutputDeviceListenerTrampoline *gOutputDeviceListener = nil;

static const AudioObjectPropertyAddress kOutputDeviceAddress = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

OSStatus outputDeviceChangedCallback(AudioObjectID inObjectID,
                                     UInt32 inNumberAddresses,
                                     const AudioObjectPropertyAddress *inAddresses,
                                     void *inClientData) {
    VibeOutputDeviceListenerTrampoline *trampoline = (__bridge VibeOutputDeviceListenerTrampoline *)(inClientData);
    // Weak → strong: nil if the delegate has since deallocated. The strong
    // local keeps it alive across the async hop to the main queue.
    id<CoreAudioSystemOutputDeviceDelegate> delegate = trampoline.delegate;
    if (!delegate) {
        return kAudioHardwareNoError;
    }
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
    gOutputDeviceListener = [[VibeOutputDeviceListenerTrampoline alloc] init];
    gOutputDeviceListener.delegate = delegate;
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kOutputDeviceAddress, &outputDeviceChangedCallback, (__bridge void *)gOutputDeviceListener);
}

+ (void)stopListeningForSystemOutputDeviceChanges {
    if (!gOutputDeviceListener) {
        return;
    }
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kOutputDeviceAddress, &outputDeviceChangedCallback, (__bridge void *)gOutputDeviceListener);
    // Release only after removal returns, so the callback's client-data pointer
    // was valid for the entire time the listener was registered.
    gOutputDeviceListener = nil;
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

// The device's available nominal-rate ranges, each wrapped as an NSValue of an
// AudioValueRange. A discrete rate is reported as a range with mMinimum ==
// mMaximum; interfaces/aggregates can report true continuous ranges.
+ (NSArray<NSValue *> *)sampleRateRangesForAudioDeviceId:(AudioDeviceID)did {
    NSMutableArray<NSValue *> *result = [[NSMutableArray alloc] init];
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
    NSUInteger count = s / sizeof(AudioValueRange); // recompute: the call may return fewer than requested
    for (NSUInteger i = 0; i < count; i++) {
        [result addObject:[NSValue valueWithBytes:&vr[i] objCType:@encode(AudioValueRange)]];
    }
    delete [] vr;
    return result;
}

+ (NSMutableArray<NSNumber *>*) supportedSampleRatesForAudioDeviceId:(AudioDeviceID)did {
    NSMutableArray<NSNumber *> *result = [[NSMutableArray alloc] init];
    // Report both ends of each range as discrete rates (a plain discrete rate
    // has mMinimum == mMaximum). Recording only the minimum, as before, hid
    // every rate above the low end of a continuous-range device.
    for (NSValue *value in [self sampleRateRangesForAudioDeviceId:did]) {
        AudioValueRange range;
        [value getValue:&range];
        [result addObject:@(range.mMinimum)];
        if (range.mMaximum != range.mMinimum) {
            [result addObject:@(range.mMaximum)];
        }
    }
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
    if (did == kAudioObjectUnknown || rate <= 0) {
        return NO;
    }
    // The nominal sample rate is a single Float64 — the whole job. The old
    // read-modify-write of kAudioDevicePropertyStreamFormat forced a 32-bit
    // depth without fixing bytes-per-frame/packet (producing an inconsistent
    // ASBD the device rejected) and read/wrote mismatched scopes. This is also
    // symmetric with the nominal-rate read in AudioPlayer.
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 nominal = rate;
    OSStatus err = AudioObjectSetPropertyData(did, &addr, 0, NULL, sizeof(nominal), &nominal);
    if (err != noErr) {
        LogError(@"CoreAudioUtil: could not set nominal sample rate to %.0f (OSStatus %d)", rate, (int)err);
        return NO;
    }
    LogDebug(@"CoreAudioUtil: setSampleRate: -> %.0f", rate);
    return YES;
}

+ (BOOL)setBestSampleRate:(double)rate forDeviceUID:(NSString *)uid {
    AudioDeviceID did = [self audioDeviceIDforUID:uid];
    NSArray<NSValue *> *ranges = [self sampleRateRangesForAudioDeviceId:did];
    if (ranges.count == 0) {
        LogError(@"CoreAudioUtil: setSampleRate: no supported rates for device");
        return NO;
    }
    // Choose the smallest supported rate >= the requested rate. A range whose
    // [min,max] straddles the request means the request itself is supported and
    // is the best possible choice.
    double best = -1;    // smallest candidate >= rate found so far
    double highest = -1; // highest supported rate, for the downgrade fallback
    for (NSValue *value in ranges) {
        AudioValueRange range;
        [value getValue:&range];
        if (range.mMaximum > highest) {
            highest = range.mMaximum;
        }
        if (rate >= range.mMinimum && rate <= range.mMaximum) {
            best = rate; // exact request supported by this range
            break;
        }
        if (rate <= range.mMinimum && (best < 0 || range.mMinimum < best)) {
            best = range.mMinimum; // smallest rate at/above the request
        }
    }
    double chosen;
    if (best >= 0) {
        chosen = best;
    } else {
        // The request exceeds every supported rate (e.g. a 192k file on a
        // 96k-max device): use the highest available rather than leaving the
        // device at a lower mismatched rate.
        chosen = highest;
        LogDebug(@"CoreAudioUtil: requested rate %.0f above device maximum; using %.0f", rate, chosen);
    }
    if (chosen <= 0) {
        return NO;
    }
    return [self setSampleRate:chosen forAudioDeviceID:did];
}

@end
