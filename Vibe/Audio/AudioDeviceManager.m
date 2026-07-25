//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioDeviceManager.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <os/lock.h>

static const AudioObjectPropertyAddress kDefaultOutputDeviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
};

static const AudioObjectPropertyAddress kDevicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
};

@interface AudioDeviceManager ()
- (void)notifyObserversUsingBlock:(void (^)(id<AudioDeviceManagerObserver> observer))block;
- (void)refreshDevicesThenNotify:(void (^)(id<AudioDeviceManagerObserver> observer))block;
@end

@implementation AudioDeviceManager {
    // Weakly-held observers. AudioPlayer registers from its serial queue while
    // the menu controller registers from the main thread, so all access goes
    // through _observersLock.
    NSHashTable<id<AudioDeviceManagerObserver>> *_observers;
    os_unfair_lock _observersLock;
    // Immutable snapshot of the output-device list, guarded by _devicesLock:
    // the refresh queue publishes while the main thread (menu rebuild,
    // outputDeviceForId: lookups) and the player queue read.
    NSArray<AudioDevice *> *_cachedOutputDevices;
    os_unfair_lock _devicesLock;
    // Serial, so overlapping HAL notifications can't publish an older sweep
    // over a newer one; also keeps the enumeration (tens of ms with
    // Bluetooth/aggregate devices) off the main thread and off the HAL's
    // notification thread.
    dispatch_queue_t _refreshQueue;
}

// The client data is the singleton, which lives for the whole process, so the
// unretained pointer can never dangle and the listeners are never removed.
static OSStatus devicePropertyChangedCallback(AudioObjectID inObjectID,
                                              UInt32 inNumberAddresses,
                                              const AudioObjectPropertyAddress *inAddresses,
                                              void *inClientData) {
    AudioDeviceManager *manager = (__bridge AudioDeviceManager *)inClientData;
    for (UInt32 i = 0; i < inNumberAddresses; i++) {
        switch (inAddresses[i].mSelector) {
            // Both selectors refresh the cache before notifying — a default
            // change moves isSystemDefault inside the snapshot, not just the
            // device list membership.
            case kAudioHardwarePropertyDefaultOutputDevice:
                [manager refreshDevicesThenNotify:^(id<AudioDeviceManagerObserver> observer) {
                    if ([observer respondsToSelector:@selector(systemDefaultOutputDeviceDidChange)]) {
                        [observer systemDefaultOutputDeviceDidChange];
                    }
                }];
                break;
            case kAudioHardwarePropertyDevices:
                [manager refreshDevicesThenNotify:^(id<AudioDeviceManagerObserver> observer) {
                    if ([observer respondsToSelector:@selector(audioOutputDevicesDidChange)]) {
                        [observer audioOutputDevicesDidChange];
                    }
                }];
                break;
        }
    }
    return kAudioHardwareNoError;
}

+ (AudioDeviceManager*)sharedInstance {
    static AudioDeviceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioDeviceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _observers = [NSHashTable weakObjectsHashTable];
        _observersLock = OS_UNFAIR_LOCK_INIT;
        _devicesLock = OS_UNFAIR_LOCK_INIT;
        // No sweep here: the singleton is first touched on the main thread
        // (observer registration), and the first outputDevices caller — at
        // launch, AudioPlayer's async init resolving the saved device on its
        // own queue — populates the cache off the main path.
        _refreshQueue = dispatch_queue_create("com.vibe.audiodevicemanager.refresh",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        // Register the HAL listeners on the refresh queue, not inline: these
        // are the process's FIRST CoreAudio calls, and bringing up the HAL
        // client connection to coreaudiod costs ~20ms — the singleton is first
        // touched on the main thread before first paint (the devices menu
        // controller's addObserver), which must not pay that. The serial
        // refresh queue keeps ordering: any refreshDevicesThenNotify queues
        // behind this block. A device change landing in the sub-100ms window
        // before the listeners attach is not missed in effect — the first
        // outputDevices sweep (AudioPlayer's async init) runs after and reads
        // the then-current device list.
        dispatch_async(_refreshQueue, ^{
            // Deliver HAL notifications on the HAL's own thread instead of the
            // main run loop; notifyObserversUsingBlock: hops to the main thread
            // itself.
            CFRunLoopRef nullRunLoop = NULL;
            AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddress, &devicePropertyChangedCallback, (__bridge void *)self);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDevicesAddress, &devicePropertyChangedCallback, (__bridge void *)self);
        });
    }
    return self;
}

- (void)addObserver:(id<AudioDeviceManagerObserver>)observer {
    if (!observer) {
        return;
    }
    os_unfair_lock_lock(&_observersLock);
    [_observers addObject:observer];
    os_unfair_lock_unlock(&_observersLock);
}

- (void)removeObserver:(id<AudioDeviceManagerObserver>)observer {
    if (!observer) {
        return;
    }
    os_unfair_lock_lock(&_observersLock);
    [_observers removeObject:observer];
    os_unfair_lock_unlock(&_observersLock);
}

// Fans a notification out to every observer on the main thread. Uses the
// common run-loop modes rather than dispatch_async(main): GCD main-queue
// blocks don't run while a menu is tracking, and the devices menu needs the
// callback while it is open.
- (void)notifyObserversUsingBlock:(void (^)(id<AudioDeviceManagerObserver> observer))block {
    os_unfair_lock_lock(&_observersLock);
    NSArray<id<AudioDeviceManagerObserver>> *observers = _observers.allObjects;
    os_unfair_lock_unlock(&_observersLock);
    if (observers.count == 0) {
        return;
    }
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        for (id<AudioDeviceManagerObserver> observer in observers) {
            block(observer);
        }
    });
    CFRunLoopWakeUp(mainRunLoop);
}

// Served from the cached snapshot; the HAL listeners keep it fresh (refresh
// first, then notify — see refreshDevicesThenNotify:). The first call (cache
// still empty) sweeps on the calling thread; concurrent first callers may
// sweep twice, with identical results, and the last store wins.
- (NSArray<AudioDevice *>*)outputDevices {
    os_unfair_lock_lock(&_devicesLock);
    NSArray<AudioDevice *> *devices = _cachedOutputDevices;
    os_unfair_lock_unlock(&_devicesLock);
    if (devices) {
        return devices;
    }
    return [self refreshOutputDevicesCache];
}

- (NSArray<AudioDevice *> *)refreshOutputDevicesCache {
    NSArray<AudioDevice *> *devices = [self enumerateOutputDevices];
    os_unfair_lock_lock(&_devicesLock);
    _cachedOutputDevices = devices;
    os_unfair_lock_unlock(&_devicesLock);
    return devices;
}

// Sweeps on the refresh queue FIRST, then fans the observer notification out
// (notifyObserversUsingBlock: hops to the main thread itself), so observers
// — AudioPlayer's removed-device fallback, an open devices menu's rebuild —
// read a cache that already reflects the change they are being told about.
- (void)refreshDevicesThenNotify:(void (^)(id<AudioDeviceManagerObserver> observer))block {
    dispatch_async(_refreshQueue, ^{
        [self refreshOutputDevicesCache];
        [self notifyObserversUsingBlock:block];
    });
}

// The full sweep: the device-list read plus per-device HAL reads (output
// channels, name, UID) — tens of ms with Bluetooth/aggregate devices present.
// Callers go through the cache above; this runs only on the refresh queue and
// on a first-use cache miss.
- (NSArray<AudioDevice *>*)enumerateOutputDevices {
    AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || size == 0) {
        return @[];
    }
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(size);
    if (!deviceIDs) {
        return @[];
    }
    NSMutableArray *result = [[NSMutableArray alloc] init];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, deviceIDs) == noErr) {
        // size is in/out: recompute from what was actually returned so a
        // device vanishing mid-query can't make us read the buffer tail.
        UInt32 count = size / sizeof(AudioDeviceID);
        AudioDeviceID defaultID = [CoreAudioUtil systemDefaultOutputDeviceID];
        for (UInt32 i = 0; i < count; i++) {
            if (![CoreAudioUtil deviceHasOutputChannels:deviceIDs[i]]) {
                continue;
            }
            AudioDevice *device = [AudioDeviceManager deviceForID:deviceIDs[i] defaultID:defaultID];
            if (device) {
                [result addObject:device];
            }
        }
    }
    free(deviceIDs);
    return result;
}

+ (AudioDevice *)deviceForID:(AudioDeviceID)deviceID defaultID:(AudioDeviceID)defaultID {
    NSString *name = [CoreAudioUtil nameForDeviceID:deviceID];
    if (!name.length) {
        return nil;
    }
    AudioDevice *device = [[AudioDevice alloc] init];
    device.name = name;
    device.uid = [CoreAudioUtil uidForDeviceID:deviceID] ?: @"default";
    device.deviceId = (NSInteger)deviceID;
    device.isSystemDefault = (deviceID == defaultID);
    return device;
}

- (AudioDevice *)outputDeviceForName:(NSString *)name {
    if (name.length == 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if ([device.name isEqualToString:name]) {
            return device;
        }
    }
    return nil;
}

- (AudioDevice *)outputDeviceForUID:(NSString *)uid {
    if (uid.length == 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if ([device.uid isEqualToString:uid]) {
            return device;
        }
    }
    return nil;
}

- (AudioDevice *)outputDeviceForId:(NSInteger)deviceId {
    if (deviceId < 0) {
        return nil;
    }
    for (AudioDevice *device in self.outputDevices) {
        if (device.deviceId == deviceId) {
            return device;
        }
    }
    return nil;
}

@end
