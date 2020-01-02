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
        [menu addItem:[NSMenuItem new]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Lock Sample Rate" action:@selector(lockSampleRate:) keyEquivalent:@""]];
    }
    NSInteger count = [self numberOfItemsInMenu:menu];

    while ([menu numberOfItems] < count)
        [menu insertItem:[NSMenuItem new] atIndex:2];
    while ([menu numberOfItems] > count)
        [menu removeItemAtIndex:2];

    for (NSInteger index = 0; index < count; index++)
        [self menu:menu updateItem:[menu itemAtIndex:index] atIndex:index shouldCancel:NO];

}

- (void)lockSampleRate:(id)lockSampleRate {
    Settings.audioPlayerLockSampleRate = !Settings.audioPlayerLockSampleRate;
    self.audioPlayer.lockSampleRate = Settings.audioPlayerLockSampleRate;
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu {
    return AudioDeviceManager.sharedInstance.numOutputDevices + 2 + 2;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel {
    if (index == [self numberOfItemsInMenu:menu] - 1) {
        item.state = StateForBOOL(Settings.audioPlayerLockSampleRate);
        item.target = self;
    }
    else if (index != 1 && index < [self numberOfItemsInMenu:menu] - 2) {
        if (index == 0) {
            index = -1;
        }
        else {
            index -= 2;
        }
        AudioDevice *device = [AudioDeviceManager.sharedInstance outputDeviceForId:(NSUInteger)index];
        item.title = device.name;
        item.state = StateForBOOL(self.audioPlayer.currentOutputDeviceIndex == index);
        item.enabled = YES;
        item.target = self;
        item.tag = index;
        item.action = @selector(changeOutputDevice:);
    }
    return YES;
}

- (IBAction) changeOutputDevice:(id)sender {
    if([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = sender;
        if (item.tag != self.audioPlayer.currentOutputDeviceIndex) {
            [self.audioPlayer setOutputDevice:item.tag];
        }
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    menuItem.enabled = YES;
    return YES;
}

@end
