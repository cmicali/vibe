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

+ (BOOL)outputUnit:(AudioUnit)unit preservesChannels:(UInt32)channels
          inStream:(AudioStreamID)stream physicalChannelCount:(UInt32)physicalChannels {
    if (!unit || channels == 0) return NO;
    UInt32 firstChannel = 0;
    if (!VibeReadDeviceProperty(stream, kAudioStreamPropertyStartingChannel,
            kAudioObjectPropertyScopeGlobal, &firstChannel, sizeof(firstChannel))) return NO;
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

+ (BOOL)readTransportType:(UInt32 *)transportType forDeviceID:(AudioDeviceID)deviceID {
    if (!transportType) {
        return NO;
    }
    *transportType = kAudioDeviceTransportTypeUnknown;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyTransportType,
                                  kAudioObjectPropertyScopeGlobal, transportType, sizeof(*transportType));
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
                                   void *value, UInt32 size) {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
    };
    return !AudioObjectHasProperty(deviceID, &address)
            || VibeReadDeviceProperty(deviceID, selector, address.mScope, value, size);
}

+ (BOOL)readOutputVolume:(Float32 *)volume balance:(Float32 *)balance mute:(BOOL *)muted
            forDeviceID:(AudioDeviceID)deviceID {
    *volume = 1.0f;
    *balance = 0.5f;
    Float32 pan = 0.5f;
    UInt32 mute = 0;
    BOOL read = VibeReadOutputControl(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                      volume, sizeof(*volume));
    read &= VibeReadOutputControl(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
                                  balance, sizeof(*balance));
    read &= VibeReadOutputControl(deviceID, kAudioDevicePropertyStereoPan, &pan, sizeof(pan));
    read &= VibeReadOutputControl(deviceID, kAudioDevicePropertyMute, &mute, sizeof(mute));
    *muted = mute != 0;
    BOOL validVolume = isfinite(*volume) && *volume >= 0 && *volume <= 1;
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
static const AudioObjectPropertyAddress kVibeOutputLevelAddress = {
    kAudioObjectPropertySelectorWildcard, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
};

+ (BOOL)addOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    OSStatus status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeOutputLevelAddress, queue, listener);
    if (status != noErr) {
        LogWarn(@"CoreAudioUtil: output level listener on %u failed (OSStatus %d)", deviceID, (int)status);
    }
    return status == noErr;
}

+ (BOOL)removeOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID {
    OSStatus status = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeOutputLevelAddress, queue, listener);
    return status == noErr || status == kAudioHardwareBadObjectError;
}

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
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
