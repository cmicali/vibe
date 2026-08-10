//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "OutputDevicesMenuController.h"
#import "AudioPlayer.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"
#import "Strings.h"

@interface OutputDevicesMenuController () <AudioDeviceManagerObserver>
@end

@implementation OutputDevicesMenuController {
    // The devices menu while it is on screen, and nil otherwise. Device
    // notifications arrive in the common run-loop modes, so an open menu can
    // be rebuilt in place when a device is plugged or unplugged, or the
    // default changes.
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
    // The System Output item's device name changes even when the list has not.
    [self refreshOpenMenu];
}

- (void)refreshOpenMenu {
    NSMenu *menu = _openMenu;
    if (menu) {
        [self menuNeedsUpdate:menu];
    }
}

// The menu layout: [0] is "System Output (<default device>)", tag -1, the
// default choice; [1] is a separator; [2] onwards is every output device. The
// checkmark tracks currentlyRequestedAudioDeviceId, where -1 checks System
// Output and anything else checks the explicitly chosen device.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    // Enumerate once and size the menu from that same snapshot. A second
    // enumeration could disagree, after a device hotplug mid-update, and
    // overrun the menu's item count.
    NSArray<AudioDevice *> *devices = AudioDeviceManager.sharedInstance.outputDevices;
    NSInteger requestedId = self.audioPlayer.currentlyRequestedAudioDeviceId;

    AudioDevice *systemDevice = nil;
    for (AudioDevice *device in devices) {
        if (device.isSystemDefault) {
            systemDevice = device;
            break;
        }
    }

    // Build the fixed header once. The device tail below resizes in place, so
    // an open menu refreshes without losing its tracking state.
    if (menu.numberOfItems < 2 || ![menu itemAtIndex:1].isSeparatorItem) {
        [menu removeAllItems];
        NSMenuItem *systemItem = [NSMenuItem new];
        systemItem.identifier = @"output_system_default";
        [menu addItem:systemItem];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *systemItem = [menu itemAtIndex:0];
    systemItem.title = systemDevice
            ? [NSString stringWithFormat:STR_MENU_OUTPUT_SYSTEM_NAMED, systemDevice.name]
            : STR_MENU_OUTPUT_SYSTEM;
    systemItem.tag = -1;
    systemItem.state = StateForBOOL(requestedId == -1);
    systemItem.enabled = YES;
    systemItem.target = self;
    systemItem.action = @selector(changeOutputDevice:);

    NSInteger count = (NSInteger)devices.count;
    while (menu.numberOfItems - 2 < count)
        [menu addItem:[NSMenuItem new]];
    while (menu.numberOfItems - 2 > count)
        [menu removeItemAtIndex:menu.numberOfItems - 1];

    NSInteger i = 2;
    for (AudioDevice *device in devices) {
        NSMenuItem *item = [menu itemAtIndex:i];
        item.title = device.name;
        item.tag = device.deviceId;
        item.state = StateForBOOL(requestedId == device.deviceId);
        item.enabled = YES;
        item.target = self;
        item.action = @selector(changeOutputDevice:);
        i++;
    }
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

@end
