//
//  CoreAudioUtil.m
//  Vibe
//

#import "CoreAudioUtil.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h> // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
#import <unistd.h>

@implementation CoreAudioUtil

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
    if (!AudioObjectHasProperty(object, &addr)) {
        return NO;
    }
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

#pragma mark - Bit-perfect output: transport, rate, physical format, volume, hog

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
    if (!AudioObjectHasProperty(deviceID, &streamsAddr)
            || AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, NULL, &size) != noErr
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
    if (AudioObjectHasProperty(first, &availableAddr)
            && AudioObjectGetPropertyDataSize(first, &availableAddr, 0, NULL, &availableSize) == noErr
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

+ (BOOL)readVirtualMainVolume:(Float32 *)volume forDeviceID:(AudioDeviceID)deviceID {
    if (!volume) {
        return NO;
    }
    *volume = 1.0f;
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress addr = { kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                        kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(deviceID, &addr)) {
        return YES; // no software volume at all: nothing scales the samples
    }
    return VibeReadDeviceProperty(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  kAudioObjectPropertyScopeOutput, volume, sizeof(*volume));
}

static BOOL VibeReadHogOwner(AudioDeviceID deviceID, pid_t *owner) {
    *owner = -1;
    return VibeReadDeviceProperty(deviceID, kAudioDevicePropertyHogMode,
                                  kAudioObjectPropertyScopeGlobal, owner, sizeof(*owner));
}

+ (BOOL)setHogOwnedByThisProcess:(BOOL)owned forDeviceID:(AudioDeviceID)deviceID {
    pid_t owner = -1;
    if (!VibeReadHogOwner(deviceID, &owner)) {
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
    if (!VibeReadHogOwner(deviceID, &owner)) {
        return NO;
    }
    return owned ? owner == me : owner != me;
}

@end
