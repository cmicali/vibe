//
//  AudioDeviceEventLog.m
//  Vibe
//

#import "AudioDeviceEventLog.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import "VibeMacros.h"

#if VIBE_VERBOSE_LOGGING
// Every property whose change the device event log records, registered only
// where a device has it: what changes on a device while Vibe holds it.
static const AudioObjectPropertyAddress kVibeEventLogDeviceAddresses[] = {
    { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyClockSource, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyClockSource, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDeviceHasChanged, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
};
// On the system object: coreaudiod restarting resets every device under the
// app, and the alert-sound output moves with the default when a device is
// taken exclusively. The default output and device list are logged from the
// snapshot and the manager's own callback.
static const AudioObjectPropertyAddress kVibeEventLogSystemAddresses[] = {
    { kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
};
static const AudioObjectPropertyAddress kVibeEventLogStreamAddresses[] = {
    { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
};

static void VibeEventLogListen(AudioObjectID object, const AudioObjectPropertyAddress *addresses, size_t count,
                               AudioObjectPropertyListenerBlock listener, BOOL add) {
    for (size_t i = 0; i < count; i++) {
        if (!AudioObjectHasProperty(object, &addresses[i])) {
            continue;
        }
        if (add) {
            // The IO thread must not wait behind the event log's property reads.
            AudioObjectAddPropertyListenerBlock(object, &addresses[i], NULL, listener);
        } else {
            AudioObjectRemovePropertyListenerBlock(object, &addresses[i], NULL, listener);
        }
    }
}

@implementation AudioDeviceEventLog {
    // Per watched device id, its name, the listener blocks and the stream
    // they sit on, which removal needs; confined to the manager's refresh
    // queue. Reads/logging run on _eventLogQueue.
    NSMutableDictionary<NSNumber *, NSDictionary *> *_eventLogWatches;
    dispatch_queue_t _eventLogQueue;
    NSInteger _eventLogDefaultID;
}

+ (AudioObjectPropertyListenerBlock)listenerForObject:(AudioObjectID)object
                                               name:(NSString *)name queue:(dispatch_queue_t)queue {
    return ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        for (UInt32 i = 0; i < count; i++) {
            AudioObjectPropertyAddress address = addresses[i];
            // TRAP: HAL delivers running/overload notifications synchronously
            // on its IO thread. A property read here can deadlock its stop.
            dispatch_async(queue, ^{
                LogInfo(@"HAL: %@ (%u) %@", name, object,
                        [CoreAudioUtil eventDescriptionOfProperty:address object:object]);
            });
        }
    };
}

// Follows the published snapshot: a device that appears is watched and says
// so, one that goes says so, and a default change is logged with its name.
- (void)watchDevices:(NSArray<AudioDevice *> *)devices {
    if (!_eventLogQueue) {
        _eventLogQueue = dispatch_queue_create("com.vibe.audiodevicemanager.eventlog", DISPATCH_QUEUE_SERIAL);
        _eventLogWatches = [NSMutableDictionary dictionary];
        _eventLogDefaultID = -1;
        VibeEventLogListen(kAudioObjectSystemObject, kVibeEventLogSystemAddresses,
                           sizeof(kVibeEventLogSystemAddresses) / sizeof(kVibeEventLogSystemAddresses[0]),
                           [AudioDeviceEventLog listenerForObject:kAudioObjectSystemObject name:@"system" queue:_eventLogQueue], YES);
    }
    size_t deviceCount = sizeof(kVibeEventLogDeviceAddresses) / sizeof(kVibeEventLogDeviceAddresses[0]);
    size_t streamCount = sizeof(kVibeEventLogStreamAddresses) / sizeof(kVibeEventLogStreamAddresses[0]);
    NSMutableSet<NSNumber *> *present = [NSMutableSet set];
    NSInteger defaultID = -1;
    NSString *defaultName = @"";
    for (AudioDevice *device in devices) {
        NSNumber *key = @(device.deviceId);
        [present addObject:key];
        if (device.isSystemDefault) {
            defaultID = device.deviceId;
            defaultName = device.name;
        }
        if (_eventLogWatches[key]) {
            continue;
        }
        NSString *name = device.name;
        AudioObjectID object = (AudioObjectID)device.deviceId;
        AudioObjectPropertyListenerBlock deviceListener = [AudioDeviceEventLog listenerForObject:object name:name queue:_eventLogQueue];
        VibeEventLogListen(object, kVibeEventLogDeviceAddresses, deviceCount, deviceListener, YES);
        AudioStreamID stream = kAudioObjectUnknown;
        AudioStreamBasicDescription physical = {0};
        [CoreAudioUtil readOutputStream:&stream physicalFormat:&physical availableFormats:NULL count:NULL forDeviceID:object];
        AudioObjectPropertyListenerBlock streamListener = [AudioDeviceEventLog listenerForObject:stream name:name queue:_eventLogQueue];
        if (stream != kAudioObjectUnknown) {
            VibeEventLogListen(stream, kVibeEventLogStreamAddresses, streamCount, streamListener, YES);
        }
        _eventLogWatches[key] = @{@"name": name, @"device": deviceListener,
                                  @"stream": streamListener, @"streamID": @(stream)};
        LogInfo(@"HAL: watching %@ (%u)", name, object);
    }
    for (NSNumber *key in _eventLogWatches.allKeys) {
        if ([present containsObject:key]) {
            continue;
        }
        NSDictionary *watch = _eventLogWatches[key];
        VibeEventLogListen(key.unsignedIntValue, kVibeEventLogDeviceAddresses, deviceCount,
                           watch[@"device"], NO);
        AudioStreamID stream = [watch[@"streamID"] unsignedIntValue];
        if (stream != kAudioObjectUnknown) {
            VibeEventLogListen(stream, kVibeEventLogStreamAddresses, streamCount, watch[@"stream"], NO);
        }
        [_eventLogWatches removeObjectForKey:key];
        LogInfo(@"HAL: %@ (%@) is gone", watch[@"name"], key);
    }
    if (defaultID != _eventLogDefaultID) {
        _eventLogDefaultID = defaultID;
        LogInfo(@"HAL: macOS default output is now %@ (%ld)", defaultName, (long)defaultID);
    }
}

@end
#endif
