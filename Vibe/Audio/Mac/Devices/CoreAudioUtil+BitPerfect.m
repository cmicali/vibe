//
//  CoreAudioUtil+BitPerfect.m
//  Vibe
//
//  Bit-perfect output: transport, rate, physical format, volume, hog.
//

#import "CoreAudioUtilInternal.h"
#import "OutputFormatRules.h"
#import "VibeMacros.h"
#import <AudioToolbox/AudioToolbox.h> // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
#import <unistd.h>
#include <math.h>

// The stream's first device channel, one-based; a zero answer is a driver
// bug and is refused here so no arithmetic on it can underflow.
BOOL VibeReadStartingChannel(AudioStreamID stream, UInt32 *firstChannel) {
    *firstChannel = 0;
    return VibeReadDeviceProperty(stream, kAudioStreamPropertyStartingChannel,
                                  kAudioObjectPropertyScopeGlobal, firstChannel, sizeof(*firstChannel))
            && *firstChannel != 0;
}

@implementation CoreAudioUtil (BitPerfect)

+ (BOOL)channelMap:(NSArray<NSNumber *> *)map preservesChannels:(UInt32)channels
          inStream:(AudioStreamID)stream physicalChannelCount:(UInt32)physicalChannels {
    if (map.count == 0 || channels == 0) return NO;
    UInt32 firstChannel = 0;
    if (!VibeReadStartingChannel(stream, &firstChannel)) return NO;
    SInt32 *entries = calloc(map.count, sizeof(SInt32));
    if (!entries) return NO;
    for (NSUInteger i = 0; i < map.count; i++) entries[i] = map[i].intValue;
    BOOL preserves = VibeBitPerfectChannelMapPreservesSource(entries, (UInt32)map.count, channels,
                                                            firstChannel, physicalChannels);
    free(entries);
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
    if (!stream || !format || (availableFormats != NULL) != (count != NULL)) {
        return NO;
    }
    *stream = kAudioObjectUnknown;
    memset(format, 0, sizeof(*format));
    if (availableFormats) {
        *availableFormats = NULL;
        *count = 0;
    }
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
    if (availableFormats && AudioObjectGetPropertyDataSize(first, &availableAddr, 0, NULL, &availableSize) == noErr
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

static const AudioObjectPropertyAddress kVibeHogModeAddress = {
    kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

+ (BOOL)addBoundDeviceListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    OSStatus status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
    if (status == noErr) {
        status = AudioObjectAddPropertyListenerBlock(deviceID, &kVibeHogModeAddress, queue, listener);
        if (status != noErr) {
            AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
        }
    }
    if (status != noErr) {
        LogWarn(@"CoreAudioUtil: bound device listener on %u failed (OSStatus %d)", deviceID, (int)status);
    }
    return status == noErr;
}

+ (BOOL)removeBoundDeviceListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID {
    OSStatus rate = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeNominalRateAddress, queue, listener);
    OSStatus hog = AudioObjectRemovePropertyListenerBlock(deviceID, &kVibeHogModeAddress, queue, listener);
    return (rate == noErr || rate == kAudioHardwareBadObjectError)
            && (hog == noErr || hog == kAudioHardwareBadObjectError);
}

+ (BOOL)readHogOwner:(pid_t *)owner forDeviceID:(AudioDeviceID)deviceID {
    *owner = -1;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyHogMode,
                                  kAudioObjectPropertyScopeGlobal, owner, sizeof(*owner));
}

+ (BOOL)deviceIsHeldByAnotherProcess:(AudioDeviceID)deviceID {
    pid_t owner = -1;
    return [self readHogOwner:&owner forDeviceID:deviceID] && owner != -1 && owner != getpid();
}

+ (BOOL)supportsHogModeForDeviceID:(AudioDeviceID)deviceID {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    return deviceID != kAudioObjectUnknown && AudioObjectHasProperty(deviceID, &address)
            && AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable;
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

@end
