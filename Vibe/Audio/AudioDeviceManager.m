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

// Setup is a HAL client connection plus one enumeration, about 20-50ms. This
// is the main thread's ceiling on waiting for it, not a target.
static const NSTimeInterval kListenerSetupMainThreadWait = 0.25;

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
    // Weakly held observers. AudioPlayer registers from its serial queue while
    // the menu controller registers from the main thread, so all access goes
    // through _observersLock.
    NSHashTable<id<AudioDeviceManagerObserver>> *_observers;
    os_unfair_lock _observersLock;
    // An immutable snapshot of the output-device list, guarded by
    // _devicesLock. The refresh queue publishes it while the main thread, for
    // menu rebuilds and outputDeviceForId: lookups, and the player queue read.
    NSArray<AudioDevice *> *_cachedOutputDevices;
    os_unfair_lock _devicesLock;
    // Serial, so that overlapping HAL notifications cannot publish an older
    // sweep over a newer one. It also keeps the enumeration, which takes tens
    // of ms when Bluetooth or aggregate devices are present, off both the main
    // thread and the HAL's notification thread.
    dispatch_queue_t _refreshQueue;
    // First-use enumeration waits until listeners are attached and one
    // post-registration sweep has closed the startup change window. Init
    // itself never waits, so first paint stays free of CoreAudio setup.
    dispatch_group_t _listenerSetupGroup;
}

// The client data is the singleton, which lives for the whole process, so the
// unretained pointer can never dangle, and the listeners are never removed.
static OSStatus devicePropertyChangedCallback(AudioObjectID inObjectID,
                                              UInt32 inNumberAddresses,
                                              const AudioObjectPropertyAddress *inAddresses,
                                              void *inClientData) {
    AudioDeviceManager *manager = (__bridge AudioDeviceManager *)inClientData;
    for (UInt32 i = 0; i < inNumberAddresses; i++) {
        switch (inAddresses[i].mSelector) {
            // Both selectors refresh the cache before notifying, because a
            // default change moves isSystemDefault inside the snapshot, not
            // just the device list's membership.
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
        // No synchronous sweep here. The singleton is first touched on the
        // main thread during observer registration; setup and its initial
        // cache fill stay on the refresh queue.
        _refreshQueue = dispatch_queue_create("com.vibe.audiodevicemanager.refresh",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        _listenerSetupGroup = dispatch_group_create();
        dispatch_group_enter(_listenerSetupGroup);
        // Register the HAL listeners on the refresh queue rather than inline.
        // These are the process's first CoreAudio calls, and bringing up the
        // HAL client connection to coreaudiod costs about 20ms. The singleton
        // is first touched on the main thread before first paint, by the
        // devices menu controller's addObserver, and that must not pay the
        // cost. outputDevices waits from its off-main first caller until this
        // block has attached listeners and published a fresh snapshot.
        dispatch_async(_refreshQueue, ^{
            // Deliver HAL notifications on the HAL's own thread rather than
            // the main run loop. notifyObserversUsingBlock: hops to the main
            // thread itself.
            CFRunLoopRef nullRunLoop = NULL;
            AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddress, &devicePropertyChangedCallback, (__bridge void *)self);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDevicesAddress, &devicePropertyChangedCallback, (__bridge void *)self);
            // Covers a change that landed before either listener attached. A
            // later change queues its own refresh behind this block.
            [self refreshOutputDevicesCache];
            dispatch_group_leave(self->_listenerSetupGroup);
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

// Fans a notification out to every observer on the main thread. It uses the
// common run-loop modes rather than dispatch_async on main, because GCD
// main-queue blocks do not run while a menu is tracking, and the devices menu
// needs the callback while it is open.
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

// Served from the cached snapshot, which the HAL listeners keep fresh by
// refreshing first and notifying second; see refreshDevicesThenNotify:.
//
// An off-main caller — AudioPlayer's async init resolving the saved device on
// its own queue, which is the first caller at launch — waits outright for
// listener setup and its mandatory refresh, and that wait is what closes the
// startup change window.
//
// The MAIN thread never waits unbounded. This getter is on the Output menu's
// update path, and the enumeration behind it is a HAL round trip that a wedged
// coreaudiod or a stalled Bluetooth device can hold indefinitely; beachballing
// the app is worse than rendering one snapshot early, which by then can only
// happen in the sub-100ms window before setup lands.
//
// TRAP: never call this from _refreshQueue. Setup runs there, so a call from
// that queue before it completes waits on a block that can no longer run.
- (NSArray<AudioDevice *>*)outputDevices {
    dispatch_time_t deadline = NSThread.isMainThread
            ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kListenerSetupMainThreadWait * NSEC_PER_SEC))
            : DISPATCH_TIME_FOREVER;
    dispatch_group_wait(_listenerSetupGroup, deadline);
    os_unfair_lock_lock(&_devicesLock);
    NSArray<AudioDevice *> *devices = _cachedOutputDevices;
    os_unfair_lock_unlock(&_devicesLock);
    return devices ?: @[];
}

// Runs only on the serial refresh queue, which orders the stores, so a newer
// sweep can never be overwritten by an older one here.
- (void)refreshOutputDevicesCache {
    NSArray<AudioDevice *> *devices = [self enumerateOutputDevices];
    os_unfair_lock_lock(&_devicesLock);
    _cachedOutputDevices = devices;
    os_unfair_lock_unlock(&_devicesLock);
}

// Sweeps on the refresh queue first, then fans the observer notification out;
// notifyObserversUsingBlock: hops to the main thread itself. Observers —
// AudioPlayer's removed-device fallback, or an open devices menu's rebuild —
// therefore read a cache that already reflects the change they are told about.
- (void)refreshDevicesThenNotify:(void (^)(id<AudioDeviceManagerObserver> observer))block {
    dispatch_async(_refreshQueue, ^{
        [self refreshOutputDevicesCache];
        [self notifyObserversUsingBlock:block];
    });
}

// The full sweep: the device-list read plus per-device HAL reads for output
// channels, name and UID. It takes tens of ms when Bluetooth or aggregate
// devices are present. Callers go through the cache above, and this runs only
// on the refresh queue and on a first-use cache miss.
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
        // size is an in-out parameter, so recompute from what was actually
        // returned. Otherwise a device vanishing mid-query could make us read
        // the buffer's tail.
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
    // Devices without a UID keep an empty uid rather than a shared sentinel.
    // Two of them would collide on a sentinel, and a persisted sentinel would
    // resolve to whichever enumerated first. outputDeviceForUID: skips empty
    // queries, so resolution for these devices falls through to the name match.
    device.uid = [CoreAudioUtil uidForDeviceID:deviceID] ?: @"";
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
