//
//  CoreAudioUtil+Diagnostics.m
//  Vibe
//

#import "CoreAudioUtilInternal.h"
#import "OutputFormatRules.h"
#import <unistd.h>

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

@implementation CoreAudioUtil (Diagnostics)

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
    VibeAddUInt32(d, @"alive", deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    VibeAddUInt32(d, @"runningSomewhere", deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere,
                  kAudioObjectPropertyScopeGlobal);
    d[@"exclusiveSupported"] = @([self supportsHogModeForDeviceID:deviceID]);
    pid_t owner = -1;
    if ([self readHogOwner:&owner forDeviceID:deviceID]) {
        d[@"exclusiveOwnerPID"] = @(owner);
        d[@"exclusiveOwnedByVibe"] = @(owner == getpid());
    }
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

@end
