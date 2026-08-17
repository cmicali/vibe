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
// is every synchronous caller's ceiling on waiting for it, not a target.
static const NSTimeInterval kListenerSetupWait = 0.25;

// How many consecutive sweeps may be discarded for a per-device property-read
// failure before one is published without the devices that failed.
//
// Discarding the whole sweep is right for a TRANSIENT failure: a device
// vanishing mid-enumeration, or coreaudiod restarting, would otherwise look
// like removal and persist a false System Output fallback. It is catastrophic
// for a PERSISTENT one — a virtual or aggregate driver that always fails a
// property read, a device with an empty name — because nothing else bounds it:
// the retry runs every two seconds for the life of the process while
// outputDevices stays empty (at launch) or frozen at the last good sweep, the
// Output menu never populates, and resolveOutputDeviceForUID: never completes,
// so the saved device can never bind. Three strikes turns that into one
// degraded-but-usable snapshot, which is what the old skip-the-bad-device
// behavior gave unconditionally.
static const NSUInteger kMaxIncompleteSweeps = 3;

static const AudioObjectPropertyAddress kDevicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
};

@interface AudioDeviceManager ()
- (void)notifyObserversUsingBlock:(void (^)(id<AudioDeviceManagerObserver> observer))block;
- (void)refreshDevicesThenNotify:(void (^)(id<AudioDeviceManagerObserver> observer))block;
- (BOOL)refreshOutputDevicesCache;
- (nullable NSArray<AudioDevice *> *)enumerateOutputDevicesAcceptingPartial:(BOOL)acceptPartial;
- (void)scheduleSnapshotRetry;
- (BOOL)registerMissingListeners;
- (void)scheduleListenerRegistrationRetry;
- (void)notifyDeviceStateRecovered;
+ (BOOL)readDeviceForID:(AudioDeviceID)deviceID
              defaultID:(AudioDeviceID)defaultID
                 device:(AudioDevice **)device;
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
    // Confined to _refreshQueue. Resolution callbacks wait for success, not
    // merely for setup to finish, so a transient HAL failure cannot be
    // mistaken for an authoritative empty device list.
    BOOL _hasSuccessfulSnapshot;
    NSMutableArray<void (^)(NSArray<AudioDevice *> *)> *_snapshotWaiters;
    BOOL _snapshotRetryScheduled;
    // Consecutive sweeps discarded for a per-device read failure. Bounds how
    // long a permanently broken device can keep the whole list unpublished;
    // see kMaxIncompleteSweeps. Confined to _refreshQueue.
    NSUInteger _incompleteSweeps;
    // Listener registration can fail transiently while coreaudiod restarts.
    // Successful registrations are never repeated; only missing ones retry.
    // Confined to _refreshQueue.
    BOOL _defaultListenerRegistered;
    BOOL _devicesListenerRegistered;
    BOOL _listenerRegistrationRetryScheduled;
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
        _snapshotWaiters = [NSMutableArray array];
        dispatch_group_enter(_listenerSetupGroup);
        // Register the HAL listeners on the refresh queue rather than inline.
        // These are the process's first CoreAudio calls, and bringing up the
        // HAL client connection to coreaudiod costs about 20ms. The singleton
        // is first touched on the main thread before first paint, by the
        // devices menu controller's addObserver, and that must not pay the
        // cost. Synchronous snapshot readers wait at most 250ms; saved-device
        // resolution instead waits asynchronously for this block to publish a
        // successful snapshot.
        dispatch_async(_refreshQueue, ^{
            // Deliver HAL notifications on the HAL's own thread rather than
            // the main run loop. notifyObserversUsingBlock: hops to the main
            // thread itself.
            CFRunLoopRef nullRunLoop = NULL;
            AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            OSStatus runLoopStatus = AudioObjectSetPropertyData(kAudioObjectSystemObject,
                    &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
            if (runLoopStatus != noErr) {
                LogWarn(@"AudioDeviceManager could not move HAL callbacks off the run loop (OSStatus %d)",
                        (int)runLoopStatus);
            }
            if (![self registerMissingListeners]) {
                [self scheduleListenerRegistrationRetry];
            }
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
// No caller waits unbounded. This getter is on both the Output menu and player
// recovery paths, and the enumeration behind it is a HAL round trip that a
// wedged coreaudiod or Bluetooth device can hold indefinitely. A briefly stale
// snapshot is safer than wedging either serial queue behind setup.
//
// TRAP: never call this from _refreshQueue. Setup runs there, so a call from
// that queue before it completes pointlessly burns the full wait ceiling on
// work which cannot advance until this call returns.
- (NSArray<AudioDevice *>*)outputDevices {
    return [self publishedOutputDevices] ?: @[];
}

// The same read, but nil rather than empty when nothing has been published
// yet. The distinction only matters to a caller deciding whether a device is
// GONE; see knowsOutputDeviceIsAbsent:.
- (nullable NSArray<AudioDevice *> *)publishedOutputDevices {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kListenerSetupWait * NSEC_PER_SEC));
    dispatch_group_wait(_listenerSetupGroup, deadline);
    os_unfair_lock_lock(&_devicesLock);
    NSArray<AudioDevice *> *devices = _cachedOutputDevices;
    os_unfair_lock_unlock(&_devicesLock);
    return devices;
}

// TRAP: absence in outputDevices is NOT removal. That getter answers @[] both
// for "no output devices exist" and for "no sweep has been published yet",
// which is what the 250ms ceiling above returns during setup or while a HAL
// failure is being retried. Reading the second as the first makes a caller fall
// back to System Output and PERSIST it, throwing away the user's device on a
// transient stall. So the removal decisions ask this instead, and it answers NO
// until a real snapshot exists to be absent from.
- (BOOL)knowsOutputDeviceIsAbsent:(NSInteger)deviceId {
    if (deviceId < 0) {
        return NO; // System Output is a policy, never a device that can vanish
    }
    NSArray<AudioDevice *> *devices = [self publishedOutputDevices];
    if (!devices) {
        return NO; // no authoritative answer yet
    }
    for (AudioDevice *device in devices) {
        if (device.deviceId == deviceId) {
            return NO;
        }
    }
    return YES;
}

// Runs only on the serial refresh queue, which orders the stores, so a newer
// sweep can never be overwritten by an older one here.
- (BOOL)refreshOutputDevicesCache {
    // A strict sweep first. Only after kMaxIncompleteSweeps consecutive
    // refusals does one run that publishes what it could read, so a transient
    // failure still never masquerades as removal while a permanent one cannot
    // keep the whole list unpublished forever.
    BOOL acceptPartial = _incompleteSweeps >= kMaxIncompleteSweeps;
    NSArray<AudioDevice *> *devices = [self enumerateOutputDevicesAcceptingPartial:acceptPartial];
    if (!devices) {
        _incompleteSweeps++;
        [self scheduleSnapshotRetry];
        return NO;
    }
    if (acceptPartial) {
        LogWarn(@"AudioDeviceManager publishing %lu output devices after %lu incomplete sweeps; "
                @"devices whose HAL properties cannot be read are omitted",
                (unsigned long)devices.count, (unsigned long)_incompleteSweeps);
    }
    _incompleteSweeps = 0;
    os_unfair_lock_lock(&_devicesLock);
    _cachedOutputDevices = devices;
    os_unfair_lock_unlock(&_devicesLock);
    _hasSuccessfulSnapshot = YES;
    NSArray<void (^)(NSArray<AudioDevice *> *)> *waiters = [_snapshotWaiters copy];
    [_snapshotWaiters removeAllObjects];
    for (void (^waiter)(NSArray<AudioDevice *> *) in waiters) {
        waiter(devices);
    }
    return YES;
}

- (void)scheduleSnapshotRetry {
    if (_snapshotRetryScheduled) {
        return;
    }
    _snapshotRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _refreshQueue, ^{
        self->_snapshotRetryScheduled = NO;
        if ([self refreshOutputDevicesCache]) {
            [self notifyDeviceStateRecovered];
        }
    });
}

- (BOOL)registerMissingListeners {
    if (!_defaultListenerRegistered) {
        OSStatus status = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                &kDefaultOutputDeviceAddress, &devicePropertyChangedCallback,
                (__bridge void *)self);
        _defaultListenerRegistered = status == noErr;
        if (!_defaultListenerRegistered) {
            LogWarn(@"AudioDeviceManager could not register default-output listener (OSStatus %d)",
                    (int)status);
        }
    }
    if (!_devicesListenerRegistered) {
        OSStatus status = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                &kDevicesAddress, &devicePropertyChangedCallback,
                (__bridge void *)self);
        _devicesListenerRegistered = status == noErr;
        if (!_devicesListenerRegistered) {
            LogWarn(@"AudioDeviceManager could not register device-list listener (OSStatus %d)",
                    (int)status);
        }
    }
    return _defaultListenerRegistered && _devicesListenerRegistered;
}

- (void)scheduleListenerRegistrationRetry {
    if (_listenerRegistrationRetryScheduled) {
        return;
    }
    _listenerRegistrationRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _refreshQueue, ^{
        self->_listenerRegistrationRetryScheduled = NO;
        if (![self registerMissingListeners]) {
            [self scheduleListenerRegistrationRetry];
            return;
        }
        // Close the gap between the last successful snapshot and listener
        // coverage, then fan out both verdicts because the missed selector is
        // unknowable.
        if ([self refreshOutputDevicesCache]) {
            [self notifyDeviceStateRecovered];
        }
    });
}

- (void)notifyDeviceStateRecovered {
    [self notifyObserversUsingBlock:^(id<AudioDeviceManagerObserver> observer) {
        if ([observer respondsToSelector:@selector(systemDefaultOutputDeviceDidChange)]) {
            [observer systemDefaultOutputDeviceDidChange];
        }
        if ([observer respondsToSelector:@selector(audioOutputDevicesDidChange)]) {
            [observer audioOutputDevicesDidChange];
        }
    }];
}

// Sweeps on the refresh queue first, then fans the observer notification out;
// notifyObserversUsingBlock: hops to the main thread itself. Observers —
// AudioPlayer's removed-device fallback, or an open devices menu's rebuild —
// therefore read a cache that already reflects the change they are told about.
- (void)refreshDevicesThenNotify:(void (^)(id<AudioDeviceManagerObserver> observer))block {
    dispatch_async(_refreshQueue, ^{
        if ([self refreshOutputDevicesCache]) {
            [self notifyObserversUsingBlock:block];
        }
    });
}

// The full sweep: the device list and default plus per-device HAL reads for
// output channels, name and UID. A partial result is not authoritative absence,
// so by default any failed read discards the whole sweep and takes the retry
// path — acceptPartial is refreshOutputDevicesCache's escape from that once a
// failure has proved persistent, and publishes the devices that did read.
//
// The list, its size and the system default are never partial: without them
// there is no sweep at all, only guesses, so those three failures return nil
// whatever acceptPartial says. This runs only on the refresh queue.
- (NSArray<AudioDevice *>*)enumerateOutputDevicesAcceptingPartial:(BOOL)acceptPartial {
    AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus sizeStatus = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
            &addr, 0, NULL, &size);
    if (sizeStatus != noErr) {
        LogWarn(@"AudioDeviceManager could not read device-list size (OSStatus %d)", (int)sizeStatus);
        return nil;
    }
    if (size == 0) {
        AudioDeviceID defaultID = kAudioObjectUnknown;
        if (![CoreAudioUtil readSystemDefaultOutputDeviceID:&defaultID]) {
            LogWarn(@"AudioDeviceManager could not read the default output device");
            return nil;
        }
        if (defaultID != kAudioObjectUnknown) {
            LogWarn(@"AudioDeviceManager empty device list named default output device %u", defaultID);
            return nil;
        }
        return @[]; // complete snapshot: no devices and no default
    }
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(size);
    if (!deviceIDs) {
        return nil;
    }
    OSStatus dataStatus = AudioObjectGetPropertyData(kAudioObjectSystemObject,
            &addr, 0, NULL, &size, deviceIDs);
    if (dataStatus != noErr) {
        free(deviceIDs);
        LogWarn(@"AudioDeviceManager could not read device list (OSStatus %d)", (int)dataStatus);
        return nil;
    }

    AudioDeviceID defaultID = kAudioObjectUnknown;
    if (![CoreAudioUtil readSystemDefaultOutputDeviceID:&defaultID]) {
        free(deviceIDs);
        LogWarn(@"AudioDeviceManager could not read the default output device");
        return nil;
    }

    NSMutableArray *result = [[NSMutableArray alloc] init];
    BOOL snapshotComplete = YES;
    BOOL foundDefault = (defaultID == kAudioObjectUnknown);
    // size is an in-out parameter, so recompute from what was actually
    // returned. Otherwise a device vanishing mid-query could make us read the
    // buffer's tail.
    UInt32 count = size / sizeof(AudioDeviceID);
    for (UInt32 i = 0; i < count; i++) {
        AudioDeviceID deviceID = deviceIDs[i];
        BOOL hasOutputChannels = NO;
        // A failed read marks the sweep incomplete but does not abandon it:
        // one unreadable device must not decide whether the others exist.
        if (![CoreAudioUtil readHasOutputChannels:&hasOutputChannels forDeviceID:deviceID]) {
            LogWarn(@"AudioDeviceManager could not read output channels for device %u", deviceID);
            snapshotComplete = NO;
            continue;
        }
        if (!hasOutputChannels) {
            continue;
        }
        AudioDevice *device = nil;
        if (![AudioDeviceManager readDeviceForID:deviceID defaultID:defaultID device:&device]) {
            LogWarn(@"AudioDeviceManager could not read identity for output device %u", deviceID);
            snapshotComplete = NO;
            continue;
        }
        [result addObject:device];
        if (deviceID == defaultID) {
            foundDefault = YES;
        }
    }
    free(deviceIDs);
    if (!foundDefault) {
        // Either the default's own reads failed above, or it enumerated with no
        // output channels — a driver oddity rather than something to reason
        // from. Both are "this sweep does not describe the system", and both
        // used to be silent unless some other read had already failed.
        LogWarn(@"AudioDeviceManager sweep did not contain default output device %u "
                @"(%lu output devices read%@)", defaultID, (unsigned long)result.count,
                snapshotComplete ? @"" : @", some reads failed");
        snapshotComplete = NO;
    }
    if (!snapshotComplete && !acceptPartial) {
        return nil;
    }
    return result;
}

+ (AudioDevice *)deviceForUID:(NSString *)uid
                         name:(NSString *)name
                    inDevices:(NSArray<AudioDevice *> *)devices {
    if (uid.length > 0) {
        for (AudioDevice *device in devices) {
            if ([device.uid isEqualToString:uid]) {
                return device;
            }
        }
    }
    if (name.length > 0) {
        for (AudioDevice *device in devices) {
            if ([device.name isEqualToString:name]) {
                return device;
            }
        }
    }
    return nil;
}

- (void)resolveOutputDeviceForUID:(NSString *)uid
                              name:(NSString *)name
                        completion:(void (^)(AudioDevice *))completion {
    if (!completion) {
        return;
    }
    NSString *savedUID = [uid copy] ?: @"";
    NSString *savedName = [name copy] ?: @"";
    dispatch_async(_refreshQueue, ^{
        void (^resolve)(NSArray<AudioDevice *> *) = ^(NSArray<AudioDevice *> *devices) {
            completion([AudioDeviceManager deviceForUID:savedUID name:savedName inDevices:devices]);
        };
        if (self->_hasSuccessfulSnapshot) {
            os_unfair_lock_lock(&self->_devicesLock);
            NSArray<AudioDevice *> *devices = self->_cachedOutputDevices ?: @[];
            os_unfair_lock_unlock(&self->_devicesLock);
            resolve(devices);
        }
        else {
            [self->_snapshotWaiters addObject:[resolve copy]];
        }
    });
}

+ (BOOL)readDeviceForID:(AudioDeviceID)deviceID
              defaultID:(AudioDeviceID)defaultID
                 device:(AudioDevice **)device {
    if (!device) {
        return NO;
    }
    *device = nil;
    NSString *name = nil;
    if (![CoreAudioUtil readName:&name forDeviceID:deviceID]) {
        return NO;
    }
    NSString *uid = nil;
    if (![CoreAudioUtil readUID:&uid forDeviceID:deviceID]) {
        return NO;
    }
    AudioDevice *readDevice = [[AudioDevice alloc] init];
    readDevice.name = name;
    // Devices without a UID keep an empty uid rather than a shared sentinel.
    // Two of them would collide on a sentinel, and a persisted sentinel would
    // resolve to whichever enumerated first. outputDeviceForUID: skips empty
    // queries, so resolution for these devices falls through to the name match.
    readDevice.uid = uid ?: @"";
    readDevice.deviceId = (NSInteger)deviceID;
    readDevice.isSystemDefault = (deviceID == defaultID);
    *device = readDevice;
    return YES;
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
