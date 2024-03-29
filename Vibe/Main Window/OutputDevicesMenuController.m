//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "OutputDevicesMenuController.h"
#import "AudioPlayer.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"

@implementation OutputDevicesMenuController {

}

- (void)menuWillOpen:(NSMenu *)menu {

}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu.numberOfItems == 0) {
//        [menu addItem:[NSMenuItem new]];
//        [menu addItem:[NSMenuItem separatorItem]];
//        [menu addItem:[NSMenuItem separatorItem]];
//        [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Lock Sample Rate" action:@selector(lockSampleRate:) keyEquivalent:@""]];
    }
    NSInteger count = [self numberOfItemsInMenu:menu];

    while ([menu numberOfItems] < count)
        [menu insertItem:[NSMenuItem new] atIndex:0];
    while ([menu numberOfItems] > count)
        [menu removeItemAtIndex:0];

    NSArray *devices = AudioDeviceManager.sharedInstance.outputDevices;
    NSMenuItem *item;

//    [self configureMenuItem:[menu itemAtIndex:0] withDevice:AudioDeviceManager.sharedInstance.defaultOutputDevice];

    int i = 0;
    for (AudioDevice *device in devices) {
        item = [menu itemAtIndex:i];
        [self configureMenuItem:item withDevice:device];
        i++;
    }

    // Lock sample rate item
    item = [menu itemAtIndex:count - 1];
    item.state = StateForBOOL(Settings.audioPlayerLockSampleRate);
    item.target = self;

}

- (void)configureMenuItem:(NSMenuItem *)item withDevice:(AudioDevice *)device {

    BOOL isRequestedDevice = self.audioPlayer.currentlyRequestedAudioDeviceId == device.deviceId;
//    BOOL isSystemDefaultDevice = AudioDeviceManager.sharedInstance.defaultOutputDeviceId == device.deviceId;

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

- (void)lockSampleRate:(id)lockSampleRate {
    Settings.audioPlayerLockSampleRate = !Settings.audioPlayerLockSampleRate;
    self.audioPlayer.lockSampleRate = Settings.audioPlayerLockSampleRate;
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
