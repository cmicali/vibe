//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "OutputDevicesMenuController.h"
#import "AudioPlayer.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"

@interface OutputDevicesMenuController () <AudioDeviceManagerObserver>
@end

@implementation OutputDevicesMenuController {
    // The devices menu while it is on screen (nil otherwise). Device
    // notifications arrive in the common run-loop modes, so an open menu can
    // be rebuilt in place when a device is (un)plugged or the default changes.
    __weak NSMenu *_openMenu;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [AudioDeviceManager.sharedInstance addObserver:self];
    }
    return self;
}

- (void)menuWillOpen:(NSMenu *)menu {
    _openMenu = menu;
}

- (void)menuDidClose:(NSMenu *)menu {
    _openMenu = nil;
}

- (void)audioOutputDevicesDidChange {
    [self refreshOpenMenu];
}

- (void)systemDefaultOutputDeviceDidChange {
    // The default-device marker icon moves even when the device list didn't.
    [self refreshOpenMenu];
}

- (void)refreshOpenMenu {
    NSMenu *menu = _openMenu;
    if (menu) {
        [self menuNeedsUpdate:menu];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    // Enumerate once and size the menu from the same snapshot: a second
    // enumeration could disagree (device hotplug mid-update) and overrun
    // the menu's item count.
    NSArray *devices = AudioDeviceManager.sharedInstance.outputDevices;
    NSInteger count = (NSInteger)devices.count;

    while ([menu numberOfItems] < count)
        [menu insertItem:[NSMenuItem new] atIndex:0];
    while ([menu numberOfItems] > count)
        [menu removeItemAtIndex:0];

    NSMenuItem *item;

    int i = 0;
    for (AudioDevice *device in devices) {
        item = [menu itemAtIndex:i];
        [self configureMenuItem:item withDevice:device];
        i++;
    }

}

- (void)configureMenuItem:(NSMenuItem *)item withDevice:(AudioDevice *)device {

    BOOL isRequestedDevice = self.audioPlayer.currentlyRequestedAudioDeviceId == device.deviceId;

    item.title = [NSString stringWithFormat:@"%@", device.name];
    item.tag = device.deviceId;

    item.state = StateForBOOL(isRequestedDevice);

    if (device.isSystemDefault && !isRequestedDevice) {
        if (self.audioPlayer.currentlyRequestedAudioDeviceId != -1) {
            item.offStateImage = [NSImage imageNamed:@"icon-system-output"];
        }
        else {
            item.offStateImage = [NSImage imageNamed:@"icon-current-output"];
        }
    }
    else {
        item.offStateImage = nil;
    }

    item.enabled = YES;
    item.target = self;
    item.action = @selector(changeOutputDevice:);
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu {
    return AudioDeviceManager.sharedInstance.numOutputDevices;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (IBAction) changeOutputDevice:(id)sender {
    if([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = sender;
        [self.audioPlayer setOutputDevice:item.tag];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    menuItem.enabled = YES;
    return YES;
}

@end
