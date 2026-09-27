//
//  OutputDevicesMenuController.m
//  Vibe
//

#import "OutputDevicesMenuController.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"
#import "AppDelegate.h"
#import "SettingsWindowController.h"
#import "SettingsGeneralViewController.h"
#import "VibeStrings.h"

@interface OutputDevicesMenuController () <AudioDeviceManagerObserver>
@end

@implementation OutputDevicesMenuController {
    // Non-nil while on screen: device notifications arrive in the common
    // run-loop modes, so an open menu rebuilds in place.
    __weak NSMenu *_openMenu;
    NSUInteger _pendingOutputDeviceSelections;
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

// [0] System Output (tag -1), [1] a separator, [2...] every output device. The
// checkmark tracks currentlyRequestedAudioDeviceId.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    // One snapshot: a second enumeration could disagree after a hotplug and
    // overrun the item count.
    NSArray<AudioDevice *> *devices = AudioDeviceManager.sharedInstance.outputDevices;
    NSInteger requestedId = self.audioPlayer.currentlyRequestedAudioDeviceId;

    AudioDevice *systemDevice = nil;
    for (AudioDevice *device in devices) {
        if (device.isSystemDefault) {
            systemDevice = device;
            break;
        }
    }

    // The tail resizes in place, so an open menu keeps its tracking state.
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
        [self selectOutputDevice:item.tag];
    }
}

- (BOOL)outputDeviceSelectionPending {
    return _pendingOutputDeviceSelections != 0;
}

- (void)selectOutputDevice:(NSInteger)deviceId {
    if (!self.audioPlayer) {
        return;
    }
    _pendingOutputDeviceSelections++;
    [[(AppDelegate *)NSApp.delegate settingsWindowController].audioPane refreshBitPerfectRows];
    [self.audioPlayer setOutputDevice:deviceId completion:^{
        self->_pendingOutputDeviceSelections--;
        [[(AppDelegate *)NSApp.delegate settingsWindowController].audioPane refreshOutputDevice];
    }];
}

@end
