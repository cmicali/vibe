//
//  CoreAudioUtil.m
//  Vibe
//

#import "CoreAudioUtilInternal.h"
#import "VibeMacros.h"
#import <CoreAudio/CoreAudio.h>
#include <stdatomic.h>

// Timed-out reads still running; while there is one, a bounded read does not wait.
static _Atomic int VibeOverdueReads;

@implementation CoreAudioUtil

+ (BOOL)performBoundedRead:(dispatch_block_t)read within:(NSTimeInterval)seconds late:(dispatch_block_t)late {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // No QoS of its own: a read runs at its caller's, which waits for it.
        queue = dispatch_queue_create("com.commonwealthrecordings.Vibe.halReads", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        read();
        dispatch_semaphore_signal(done);
    });
    BOOL overdue = atomic_load(&VibeOverdueReads) > 0;
    if (dispatch_semaphore_wait(done, overdue ? DISPATCH_TIME_NOW
                                : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0) {
        return YES;
    }
    BOOL counted = seconds > 0 && !overdue;
    if (counted) {
        atomic_fetch_add(&VibeOverdueReads, 1);
    }
    dispatch_async(queue, ^{
        if (counted) {
            atomic_fetch_sub(&VibeOverdueReads, 1);
        }
        if (late) late();
    });
    return NO;
}

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
BOOL VibeReadDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                            AudioObjectPropertyScope scope, void *value, UInt32 size) {
    if (object == kAudioObjectUnknown || !value) {
        return NO;
    }
    AudioObjectPropertyAddress addr = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 ioSize = size;
    return AudioObjectGetPropertyData(object, &addr, 0, NULL, &ioSize, value) == noErr
            && ioSize == size;
}

BOOL VibeWriteDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
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

@end
