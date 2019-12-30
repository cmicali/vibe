//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "DevicesMenuController.h"
#import "BassWrapper.h"
#import "AudioPlayer.h"
#import "AudioDevice.h"

@implementation DevicesMenuController {

}

- (void)menuWillOpen:(NSMenu *)menu {

}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu.numberOfItems == 0) {
        [menu insertItem:[NSMenuItem new] atIndex:0];
        [menu insertItem:[NSMenuItem separatorItem] atIndex:1];
    }
    NSInteger count = [self numberOfItemsInMenu:menu];

    while ([menu numberOfItems] < count)
        [menu insertItem:[NSMenuItem new] atIndex:2];
    while ([menu numberOfItems] > count)
        [menu removeItemAtIndex:2];

    for (NSInteger index = 0; index < count; index++)
        [self menu:menu updateItem:[menu itemAtIndex:index] atIndex:index shouldCancel:NO];

}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu {
    return self.audioPlayer.numOutputDevices + 2;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel {
    if (index != 1) {
        if (index == 0) {
            index = -1;
        }
        else {
            index -= 2;
        }
        AudioDevice *device = [self.audioPlayer outputDeviceForIndex:index];
        item.title = device.name;
        item.state = (self.audioPlayer.currentOutputDeviceIndex == index) ? NSControlStateValueOn : NSControlStateValueOff;
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
            if ([self.audioPlayer setOutputDevice:item.tag]) {
                Settings.audioPlayerCurrentDevice = self.audioPlayer.currentOutputDeviceIndex;
            }
        }
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    menuItem.enabled = YES;
    return YES;
}


@end
