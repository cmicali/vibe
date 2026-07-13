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
@end

@implementation AudioDeviceManager {
    // Weakly-held observers. AudioPlayer registers from its serial queue while
    // the menu controller registers from the main thread, so all access goes
    // through _observersLock.
    NSHashTable<id<AudioDeviceManagerObserver>> *_observers;
    os_unfair_lock _observersLock;
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
            case kAudioHardwarePropertyDefaultOutputDevice:
                [manager notifyObserversUsingBlock:^(id<AudioDeviceManagerObserver> observer) {
                    if ([observer respondsToSelector:@selector(systemDefaultOutputDeviceDidChange)]) {
                        [observer systemDefaultOutputDeviceDidChange];
                    }
                }];
                break;
            case kAudioHardwarePropertyDevices:
                [manager notifyObserversUsingBlock:^(id<AudioDeviceManagerObserver> observer) {
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
        // Deliver HAL notifications on the HAL's own thread instead of the
        // main run loop; notifyObserversUsingBlock: hops to the main thread
        // itself.
        CFRunLoopRef nullRunLoop = NULL;
        AudioObjectPropertyAddress runLoopProperty = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddress, &devicePropertyChangedCallback, (__bridge void *)self);
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDevicesAddress, &devicePropertyChangedCallback, (__bridge void *)self);
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

- (NSArray<AudioDevice *>*)outputDevices {
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

- (NSInteger)numOutputDevices {
    return (NSInteger)self.outputDevices.count;
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
