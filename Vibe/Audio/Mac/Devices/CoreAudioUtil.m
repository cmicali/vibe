//
//  CoreAudioUtil.m
//  Vibe
//

#import "CoreAudioUtil.h"
#import "OutputFormatRules.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h> // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
#import <unistd.h>
#include <math.h>

@implementation CoreAudioUtil

+ (BOOL)releaseDeviceObligation:(AudioDeviceID *)deviceID attempt:(BOOL (^)(void))attempt
                      isAbsent:(BOOL (^)(AudioDeviceID))isAbsent {
    if (*deviceID == kAudioObjectUnknown) return YES;
    for (NSUInteger retry = 0; retry < 2; retry++) {
        if (attempt() || isAbsent(*deviceID)) {
            *deviceID = kAudioObjectUnknown;
            return YES;
        }
    }
    return NO;
}


+ (AudioDeviceID)systemDefaultOutputDeviceID {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    [self readSystemDefaultOutputDeviceID:&deviceID];
    return deviceID;
}

// One fixed-size property read or write, with the answer separate from the
// success: the shape every accessor below is written in.
static BOOL VibeReadDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope, void *value, UInt32 size) {
    if (object == kAudioObjectUnknown || !value) {
        return NO;
    }
    AudioObjectPropertyAddress addr = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 ioSize = size;
    return AudioObjectGetPropertyData(object, &addr, 0, NULL, &ioSize, value) == noErr
            && ioSize == size;
}

static BOOL VibeWriteDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                                    const void *value, UInt32 size) {
    if (object == kAudioObjectUnknown || !value) {
        return NO;
    }
    AudioObjectPropertyAddress addr = { selector, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectSetPropertyData(object, &addr, 0, NULL, size, value);
    if (status != noErr) {
        LogWarn(@"CoreAudioUtil: set property '%c%c%c%c' on %u failed (OSStatus %d)",
                (char)(selector >> 24), (char)(selector >> 16), (char)(selector >> 8), (char)selector,
                object, (int)status);
    }
    return status == noErr;
}

+ (BOOL)readSystemDefaultOutputDeviceID:(AudioDeviceID *)deviceID {
    if (!deviceID) {
        return NO;
    }
    *deviceID = kAudioObjectUnknown;
    return VibeReadDeviceProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                                  kAudioObjectPropertyScopeGlobal, deviceID, sizeof(*deviceID));
}

+ (BOOL)readModelUID:(NSString **)modelUID forDeviceID:(AudioDeviceID)deviceID {
    if (!modelUID) {
        return NO;
    }
    *modelUID = nil;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyModelUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
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
    *modelUID = CFBridgingRelease(value);
    return YES;
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

#pragma mark - Bit-perfect output: transport, rate, physical format, volume, hog

// The stream's first device channel, one-based; a zero answer is a driver
// bug and is refused here so no arithmetic on it can underflow.
static BOOL VibeReadStartingChannel(AudioStreamID stream, UInt32 *firstChannel) {
    *firstChannel = 0;
    return VibeReadDeviceProperty(stream, kAudioStreamPropertyStartingChannel,
                                  kAudioObjectPropertyScopeGlobal, firstChannel, sizeof(*firstChannel))
            && *firstChannel != 0;
}

+ (BOOL)outputUnit:(AudioUnit)unit preservesChannels:(UInt32)channels
          inStream:(AudioStreamID)stream physicalChannelCount:(UInt32)physicalChannels {
    if (!unit || channels == 0) return NO;
    UInt32 firstChannel = 0;
    if (!VibeReadStartingChannel(stream, &firstChannel)) return NO;
    AudioStreamBasicDescription output = {0};
    UInt32 size = sizeof(output);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
            0, &output, &size) != noErr || size != sizeof(output)) return NO;
    Boolean writable = false;
    if (AudioUnitGetPropertyInfo(unit, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Input, 0, &size, &writable) != noErr || size == 0
            || size != (uint64_t)output.mChannelsPerFrame * sizeof(SInt32)) return NO;
    UInt32 capacity = size;
    SInt32 *map = malloc(capacity);
    if (!map) return NO;
    BOOL preserves = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Input, 0, map, &size) == noErr && size == capacity
            && VibeBitPerfectChannelMapPreservesSource(map, size / sizeof(*map), channels,
                                                       firstChannel, physicalChannels);
    free(map);
    return preserves;
}

+ (BOOL)deviceIsConfirmedDead:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    UInt32 isAlive = 1;
    UInt32 size = sizeof(isAlive);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &isAlive);
    return VibeDeviceIsConfirmedDead(status, isAlive);
}

+ (BOOL)readTransportType:(UInt32 *)transportType forDeviceID:(AudioDeviceID)deviceID {
    if (!transportType) {
        return NO;
    }
    *transportType = kAudioDeviceTransportTypeUnknown;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyTransportType,
                                  kAudioObjectPropertyScopeGlobal, transportType, sizeof(*transportType));
}

+ (BOOL)isProcessPrivateAggregateDevice:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
            kAudioAggregateDevicePropertyComposition,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    // Absent on every non-aggregate, which is the common case and not a failure.
    if (!AudioObjectHasProperty(deviceID, &addr)) {
        return NO;
    }
    CFDictionaryRef composition = NULL;
    UInt32 size = sizeof(composition);
    if (AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &composition) != noErr
            || composition == NULL) {
        return NO;
    }
    NSNumber *isPrivate = [(__bridge NSDictionary *)composition
            objectForKey:@kAudioAggregateDeviceIsPrivateKey];
    CFRelease(composition);
    // The key is optional, and its absence means published to the whole system.
    return [isPrivate isKindOfClass:[NSNumber class]] && isPrivate.intValue != 0;
}

+ (BOOL)readNominalSampleRate:(Float64 *)rate forDeviceID:(AudioDeviceID)deviceID {
    if (!rate) {
        return NO;
    }
    *rate = 0;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyNominalSampleRate,
                                  kAudioObjectPropertyScopeGlobal, rate, sizeof(*rate));
}

+ (BOOL)readOutputStream:(AudioStreamID *)stream
          physicalFormat:(AudioStreamBasicDescription *)format
        availableFormats:(AudioStreamRangedDescription **)availableFormats
                   count:(UInt32 *)count
             forDeviceID:(AudioDeviceID)deviceID {
    if (!stream || !format || !availableFormats || !count) {
        return NO;
    }
    *stream = kAudioObjectUnknown;
    memset(format, 0, sizeof(*format));
    *availableFormats = NULL;
    *count = 0;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress streamsAddr = { kAudioDevicePropertyStreams,
                                               kAudioObjectPropertyScopeOutput,
                                               kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, NULL, &size) != noErr
            || size < sizeof(AudioStreamID)) {
        return NO;
    }
    AudioStreamID *streams = (AudioStreamID *)malloc(size);
    if (!streams) {
        return NO;
    }
    if (AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, NULL, &size, streams) != noErr
            || size < sizeof(AudioStreamID)) {
        free(streams);
        return NO;
    }
    AudioStreamID first = streams[0];
    free(streams);
    if (![self readPhysicalFormat:format forStream:first]) {
        return NO;
    }
    AudioObjectPropertyAddress availableAddr = { kAudioStreamPropertyAvailablePhysicalFormats,
                                                 kAudioObjectPropertyScopeGlobal,
                                                 kAudioObjectPropertyElementMain };
    UInt32 availableSize = 0;
    if (AudioObjectGetPropertyDataSize(first, &availableAddr, 0, NULL, &availableSize) == noErr
            && availableSize >= sizeof(AudioStreamRangedDescription)) {
        AudioStreamRangedDescription *formats = (AudioStreamRangedDescription *)malloc(availableSize);
        if (formats && AudioObjectGetPropertyData(first, &availableAddr, 0, NULL,
                                                  &availableSize, formats) == noErr) {
            *availableFormats = formats;
            *count = availableSize / sizeof(AudioStreamRangedDescription);
        }
        else {
            free(formats);
        }
    }
    *stream = first;
    return YES;
}

+ (BOOL)readPhysicalFormat:(AudioStreamBasicDescription *)format forStream:(AudioStreamID)stream {
    return VibeReadDeviceProperty(stream, kAudioStreamPropertyPhysicalFormat,
                                  kAudioObjectPropertyScopeGlobal, format, sizeof(*format));
}

+ (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format forStream:(AudioStreamID)stream {
    return VibeWriteDeviceProperty(stream, kAudioStreamPropertyPhysicalFormat, &format, sizeof(format));
}

// Keep the absence/failure distinction in one place for all optional controls.
static BOOL VibeReadOutputControl(AudioDeviceID deviceID, AudioObjectPropertySelector selector,
                                   AudioObjectPropertyElement element, void *value, UInt32 size) {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeOutput, element
    };
    UInt32 ioSize = size;
    return !AudioObjectHasProperty(deviceID, &address)
            || (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &ioSize, value) == noErr
                && ioSize == size);
}

+ (BOOL)readOutputVolume:(Float32 *)volume balance:(Float32 *)balance mute:(BOOL *)muted
               channels:(UInt32)channels inStream:(AudioStreamID)stream
            forDeviceID:(AudioDeviceID)deviceID {
    *volume = 1.0f;
    *balance = 0.5f;
    Float32 pan = 0.5f;
    UInt32 mute = 0;
    BOOL read = VibeReadOutputControl(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                      kAudioObjectPropertyElementMain, volume, sizeof(*volume));
    read &= VibeReadOutputControl(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
                                  kAudioObjectPropertyElementMain, balance, sizeof(*balance));
    read &= VibeReadOutputControl(deviceID, kAudioDevicePropertyStereoPan,
                                  kAudioObjectPropertyElementMain, &pan, sizeof(pan));
    BOOL validVolume = isfinite(*volume) && *volume >= 0 && *volume <= 1;
    *muted = NO;
    UInt32 firstChannel = 0;
    if (channels && (!VibeReadStartingChannel(stream, &firstChannel)
            || channels > UINT32_MAX - firstChannel)) {
        read = NO;
        channels = 0;
    }
    // Virtual volume/balance cover the preferred layout, which need not be
    // this stream. Check its actual channels and the driver's main controls.
    for (UInt32 channel = 0; channel <= channels; channel++) {
        UInt32 element = channel ? firstChannel + channel - 1 : kAudioObjectPropertyElementMain;
        Float32 scalar = 1;
        mute = 0;
        read &= VibeReadOutputControl(deviceID, kAudioDevicePropertyVolumeScalar,
                                      element, &scalar, sizeof(scalar));
        read &= VibeReadOutputControl(deviceID, kAudioDevicePropertyMute,
                                      element, &mute, sizeof(mute));
        BOOL validScalar = isfinite(scalar) && scalar >= 0 && scalar <= 1;
        validVolume &= validScalar;
        if (validScalar) *volume = MIN(*volume, scalar);
        *muted |= mute != 0;
    }
    BOOL validBalance = isfinite(*balance) && *balance >= 0 && *balance <= 1;
    BOOL validPan = isfinite(pan) && pan >= 0 && pan <= 1;
    // Virtual balance and a driver pan control can coexist; either may scale a channel.
    if (validBalance && validPan && *balance == 0.5f) *balance = pan;
    // Keep invalid driver values out of the published/debug snapshot. The
    // failed confirmation still prevents these defaults from reporting Active.
    if (!validVolume) *volume = 1.0f;
    if (!validBalance || !validPan) *balance = 0.5f;
    return read && validVolume && validBalance && validPan;
}

// One registration and lifetime, including devices with only some controls.
// The nominal rate is a global-scope property the output wildcard does not
// cover, so it rides the same block under its own address.
static const AudioObjectPropertyAddress kVibeOutputLevelAddress = {
    kAudioObjectPropertySelectorWildcard, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard
};
static const AudioObjectPropertyAddress kVibeNominalRateAddress = {
    kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

+ (BOOL)addOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    OSStatus status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeOutputLevelAddress, queue, listener);
    if (status == noErr) {
        status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
        if (status != noErr) {
            AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeOutputLevelAddress, queue, listener);
        }
    }
    if (status != noErr) {
        LogWarn(@"CoreAudioUtil: output level listener on %u failed (OSStatus %d)", deviceID, (int)status);
    }
    return status == noErr;
}

+ (BOOL)removeOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID {
    OSStatus levels = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeOutputLevelAddress, queue, listener);
    OSStatus rate = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
    return (levels == noErr || levels == kAudioHardwareBadObjectError)
            && (rate == noErr || rate == kAudioHardwareBadObjectError);
}

+ (BOOL)addNominalRateListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    OSStatus status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
    if (status != noErr) {
        LogWarn(@"CoreAudioUtil: nominal rate listener on %u failed (OSStatus %d)", deviceID, (int)status);
    }
    return status == noErr;
}

+ (BOOL)removeNominalRateListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID {
    OSStatus status = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
    return status == noErr || status == kAudioHardwareBadObjectError;
}

#pragma mark - Diagnostics

static NSString *VibeFourCCText(UInt32 code) {
    char c[5] = { (char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0 };
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) {
            return [NSString stringWithFormat:@"0x%08x", (unsigned)code];
        }
    }
    return @(c);
}

// "44100 Hz i24 2ch", the bit-perfect log lines' wording plus the channel
// count; a ranged entry shows its span, a non-PCM one its format code.
static NSString *VibeFormatText(AudioStreamBasicDescription format, AudioValueRange rates) {
    NSString *rate = rates.mMinimum > 0 && rates.mMinimum != rates.mMaximum
            ? [NSString stringWithFormat:@"%.0f-%.0f Hz", rates.mMinimum, rates.mMaximum]
            : [NSString stringWithFormat:@"%.0f Hz", format.mSampleRate > 0 ? format.mSampleRate : rates.mMinimum];
    NSString *sample = format.mFormatID == kAudioFormatLinearPCM
            ? [NSString stringWithFormat:@"%@%u", VibePhysicalFormatIsFloat(format) ? @"f" : @"i",
               (unsigned)format.mBitsPerChannel]
            : VibeFourCCText(format.mFormatID);
    return [NSString stringWithFormat:@"%@ %@ %uch", rate, sample, (unsigned)format.mChannelsPerFrame];
}

static NSString *VibeReadObjectString(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = { selector, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(object, &addr)) {
        return nil;
    }
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value);
    if (status != noErr || !value) {
        if (value) {
            CFRelease(value);
        }
        return nil;
    }
    return CFBridgingRelease(value);
}

static void VibeAddUInt32(NSMutableDictionary *d, NSString *key, AudioObjectID object,
                          AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    UInt32 value = 0;
    if (VibeReadDeviceProperty(object, selector, scope, &value, sizeof(value))) {
        d[key] = @(value);
    }
}

// The name Audio MIDI Setup shows as the clock source, through the ID-to-name
// translation the HAL offers for it.
static NSString *VibeReadClockSourceName(AudioDeviceID deviceID) {
    const AudioObjectPropertyScope scopes[] = { kAudioObjectPropertyScopeGlobal,
                                                kAudioObjectPropertyScopeOutput };
    for (size_t i = 0; i < sizeof(scopes) / sizeof(scopes[0]); i++) {
        AudioObjectPropertyScope scope = scopes[i];
        UInt32 source = 0;
        if (!VibeReadDeviceProperty(deviceID, kAudioDevicePropertyClockSource, scope, &source, sizeof(source))) {
            continue;
        }
        CFStringRef name = NULL;
        AudioValueTranslation translation = { &source, sizeof(source), &name, sizeof(name) };
        AudioObjectPropertyAddress addr = { kAudioDevicePropertyClockSourceNameForIDCFString, scope,
                                            kAudioObjectPropertyElementMain };
        UInt32 size = sizeof(translation);
        if (AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &translation) == noErr && name) {
            return CFBridgingRelease(name);
        }
        return VibeFourCCText(source);
    }
    return nil;
}

static NSArray<NSString *> *VibeReadAvailableRates(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyAvailableNominalSampleRates,
                                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size) != noErr
            || size < sizeof(AudioValueRange)) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, data.mutableBytes) != noErr) {
        return nil;
    }
    NSMutableArray<NSString *> *rates = [NSMutableArray array];
    const AudioValueRange *ranges = data.bytes;
    for (UInt32 i = 0; i < size / sizeof(AudioValueRange); i++) {
        [rates addObject:ranges[i].mMinimum == ranges[i].mMaximum
                ? [NSString stringWithFormat:@"%.0f", ranges[i].mMinimum]
                : [NSString stringWithFormat:@"%.0f-%.0f", ranges[i].mMinimum, ranges[i].mMaximum]];
    }
    return rates;
}

+ (NSDictionary<NSString *, id> *)diagnosticDescriptionOfDeviceID:(AudioDeviceID)deviceID {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = @(deviceID);
    NSString *text = nil;
    if ([self readName:&text forDeviceID:deviceID] && text) d[@"name"] = text;
    if ([self readUID:&text forDeviceID:deviceID] && text) d[@"uid"] = text;
    if ([self readModelUID:&text forDeviceID:deviceID] && text.length) d[@"modelUID"] = text;
    d[@"manufacturer"] = VibeReadObjectString(deviceID, kAudioObjectPropertyManufacturer);
    UInt32 transport = 0;
    if ([self readTransportType:&transport forDeviceID:deviceID]) d[@"transport"] = VibeFourCCText(transport);
    d[@"processPrivateAggregate"] = @([self isProcessPrivateAggregateDevice:deviceID]);
    VibeAddUInt32(d, @"alive", deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    VibeAddUInt32(d, @"runningSomewhere", deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere,
                  kAudioObjectPropertyScopeGlobal);
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    d[@"exclusiveSupported"] = @([self supportsHogModeForDeviceID:deviceID]);
    pid_t owner = -1;
    if ([self readHogOwner:&owner forDeviceID:deviceID]) {
        d[@"exclusiveOwnerPID"] = @(owner);
        d[@"exclusiveOwnedByVibe"] = @(owner == getpid());
    }
#endif
    Float64 rate = 0;
    if ([self readNominalSampleRate:&rate forDeviceID:deviceID]) d[@"nominalSampleRate"] = @(rate);
    d[@"availableNominalSampleRates"] = VibeReadAvailableRates(deviceID);
    VibeAddUInt32(d, @"bufferFrameSize", deviceID, kAudioDevicePropertyBufferFrameSize,
                  kAudioObjectPropertyScopeGlobal);
    AudioValueRange bufferRange = {0};
    if (VibeReadDeviceProperty(deviceID, kAudioDevicePropertyBufferFrameSizeRange,
                               kAudioObjectPropertyScopeGlobal, &bufferRange, sizeof(bufferRange))) {
        d[@"bufferFrameSizeRange"] = [NSString stringWithFormat:@"%.0f-%.0f",
                                      bufferRange.mMinimum, bufferRange.mMaximum];
    }
    VibeAddUInt32(d, @"outputLatencyFrames", deviceID, kAudioDevicePropertyLatency,
                  kAudioObjectPropertyScopeOutput);
    VibeAddUInt32(d, @"outputSafetyOffsetFrames", deviceID, kAudioDevicePropertySafetyOffset,
                  kAudioObjectPropertyScopeOutput);
    d[@"clockSource"] = VibeReadClockSourceName(deviceID);

    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription physical = {0};
    AudioStreamRangedDescription *available = NULL;
    UInt32 availableCount = 0;
    if ([self readOutputStream:&stream physicalFormat:&physical availableFormats:&available
                         count:&availableCount forDeviceID:deviceID]) {
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        s[@"id"] = @(stream);
        s[@"physicalFormat"] = VibeFormatText(physical, (AudioValueRange){0});
        AudioStreamBasicDescription virtual = {0};
        if (VibeReadDeviceProperty(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
                                   &virtual, sizeof(virtual))) {
            s[@"virtualFormat"] = VibeFormatText(virtual, (AudioValueRange){0});
        }
        NSMutableOrderedSet<NSString *> *formats = [NSMutableOrderedSet orderedSet];
        for (UInt32 i = 0; i < availableCount; i++) {
            [formats addObject:VibeFormatText(available[i].mFormat, available[i].mSampleRateRange)];
        }
        s[@"availablePhysicalFormats"] = formats.array;
        VibeAddUInt32(s, @"latencyFrames", stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
        UInt32 firstChannel = 0;
        if (VibeReadStartingChannel(stream, &firstChannel)) s[@"startingChannel"] = @(firstChannel);
        Float32 volume = 1, balance = 0.5f;
        BOOL muted = NO;
        if ([self readOutputVolume:&volume balance:&balance mute:&muted channels:physical.mChannelsPerFrame
                          inStream:stream forDeviceID:deviceID]) {
            s[@"volume"] = @(volume);
            s[@"balance"] = @(balance);
            s[@"muted"] = @(muted);
        }
        d[@"outputStream"] = s;
    }
    free(available);
    return d;
}

#if VIBE_VERBOSE_LOGGING
+ (NSString *)eventDescriptionOfProperty:(AudioObjectPropertyAddress)address object:(AudioObjectID)object {
    UInt32 u = 0;
    BOOL haveU = VibeReadDeviceProperty(object, address.mSelector, address.mScope, &u, sizeof(u));
    NSString *value = haveU ? [NSString stringWithFormat:@"%u", (unsigned)u] : @"?";
    switch (address.mSelector) {
        case kAudioDevicePropertyDeviceIsAlive:             return [@"alive = " stringByAppendingString:value];
        case kAudioDevicePropertyDeviceIsRunning:           return [@"running = " stringByAppendingString:value];
        case kAudioDevicePropertyDeviceIsRunningSomewhere:  return [@"running somewhere = " stringByAppendingString:value];
        case kAudioDevicePropertyBufferFrameSize:           return [NSString stringWithFormat:@"buffer = %@ frames", value];
        case kAudioDevicePropertyLatency:                   return [NSString stringWithFormat:@"latency = %@ frames", value];
        case kAudioDevicePropertySafetyOffset:              return [NSString stringWithFormat:@"safety offset = %@ frames", value];
        case kAudioDevicePropertyMute:                      return [@"mute = " stringByAppendingString:value];
        case kAudioDevicePropertyJackIsConnected:           return [@"jack connected = " stringByAppendingString:value];
        case kAudioStreamPropertyIsActive:                  return [@"stream active = " stringByAppendingString:value];
        case kAudioDevicePropertyDataSource:
            return [@"data source = " stringByAppendingString:haveU ? VibeFourCCText(u) : @"?"];
        case kAudioDeviceProcessorOverload:                 return @"IO overload: a cycle was dropped";
        case kAudioDevicePropertyIOStoppedAbnormally:       return @"IO stopped abnormally";
        case kAudioHardwarePropertyServiceRestarted:        return @"coreaudiod restarted";
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return [@"alert sound output is now device " stringByAppendingString:value];
        case kAudioDevicePropertyDeviceHasChanged:          return @"reports it has changed";
        case kAudioDevicePropertyClockSource:
            return [@"clock source = " stringByAppendingString:VibeReadClockSourceName(object) ?: @"?"];
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 rate = 0;
            VibeReadDeviceProperty(object, address.mSelector, address.mScope, &rate, sizeof(rate));
            return [NSString stringWithFormat:@"nominal rate = %.0f Hz", rate];
        }
        case kAudioDevicePropertyVolumeScalar: {
            Float32 volume = 0;
            VibeReadDeviceProperty(object, address.mSelector, address.mScope, &volume, sizeof(volume));
            return [NSString stringWithFormat:@"volume = %.3f", volume];
        }
        case kAudioDevicePropertyStreams: {
            UInt32 size = 0;
            AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size);
            return [NSString stringWithFormat:@"output streams = %u", (unsigned)(size / sizeof(AudioStreamID))];
        }
        case kAudioDevicePropertyHogMode: {
            pid_t owner = -1;
            VibeReadDeviceProperty(object, address.mSelector, address.mScope, &owner, sizeof(owner));
            return [NSString stringWithFormat:@"exclusive owner = %d%@", owner,
                    owner == getpid() ? @" (Vibe)" : owner == -1 ? @" (none)" : @""];
        }
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyVirtualFormat: {
            AudioStreamBasicDescription format = {0};
            VibeReadDeviceProperty(object, address.mSelector, address.mScope, &format, sizeof(format));
            return [NSString stringWithFormat:@"%@ format = %@",
                    address.mSelector == kAudioStreamPropertyPhysicalFormat ? @"physical" : @"virtual",
                    VibeFormatText(format, (AudioValueRange){0})];
        }
    }
    return [NSString stringWithFormat:@"%@ changed", VibeFourCCText(address.mSelector)];
}
#endif

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
+ (BOOL)supportsHogModeForDeviceID:(AudioDeviceID)deviceID {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    return deviceID != kAudioObjectUnknown && AudioObjectHasProperty(deviceID, &address)
            && AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable;
}

+ (BOOL)readHogOwner:(pid_t *)owner forDeviceID:(AudioDeviceID)deviceID {
    *owner = -1;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyHogMode,
                                  kAudioObjectPropertyScopeGlobal, owner, sizeof(*owner));
}

+ (BOOL)setHogOwnedByThisProcess:(BOOL)owned forDeviceID:(AudioDeviceID)deviceID {
    pid_t owner = -1;
    if (![self readHogOwner:&owner forDeviceID:deviceID]) {
        return NO;
    }
    pid_t me = getpid();
    // "Owned by this process" is the whole state: a release with another
    // process holding it is already true, and an acquire over another holder
    // is refused by the HAL itself (the write leaves it unchanged, and the
    // read-back below says so).
    if (owned ? owner == me : owner != me) {
        return YES; // already in the requested state; a write here would toggle it
    }
    pid_t request = owned ? me : -1;
    if (!VibeWriteDeviceProperty(deviceID, kAudioDevicePropertyHogMode, &request, sizeof(request))) {
        return NO;
    }
    if (![self readHogOwner:&owner forDeviceID:deviceID]) {
        return NO;
    }
    return owned ? owner == me : owner != me;
}
#endif

@end
