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
    NSInteger count = [self numberOfItemsInMenu:menu];
    while ([menu numberOfItems] < count)
        [menu insertItem:[NSMenuItem new] atIndex:0];
    while ([menu numberOfItems] > count)
        [menu removeItemAtIndex:0];
    for (NSInteger index = 0; index < count; index++)
        [self menu:menu updateItem:[menu itemAtIndex:index] atIndex:index shouldCancel:NO];

}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu {
    return self.audioPlayer.numDevices;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel {
    AudioDevice *device = [self.audioPlayer deviceForIndex:index + 1];
    item.title = device.name;
    item.state = (self.audioPlayer.currentDeviceIndex == index + 1) ? NSControlStateValueOn : NSControlStateValueOff;
    item.enabled = YES;
    item.target = self;
    return YES;
}

- (IBAction) changeOutputDevice:(id)sender {

}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    menuItem.enabled = YES;
    return YES;
}


@end
