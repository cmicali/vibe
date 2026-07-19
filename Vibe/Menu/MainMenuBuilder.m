//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "OutputDevicesMenuController.h"

@implementation MainMenuBuilder {
    __weak AppDelegate           *_appDelegate;
    __weak MainPlayerController  *_playerController;
    NSMenu                       *_openRecentMenu;
}

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate
                   playerController:(MainPlayerController *)playerController {
    self = [super init];
    if (self) {
        _appDelegate = appDelegate;
        _playerController = playerController;
    }
    return self;
}

static NSMenuItem *VibeMenuItem(NSString *title, SEL action, id target, NSString *key,
                                NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    // NSMenuItem defaults to a Command modifier; the transport keys (space,
    // b, n, p, tab) are bare so the mask must be set explicitly every time.
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    item.identifier = identifier;
    return item;
}

static NSMenuItem *VibeSubmenuItem(NSMenu *parent, NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    item.submenu = [[NSMenu alloc] initWithTitle:title];
    [parent addItem:item];
    return item;
}

- (void)installMainMenu {
    AppDelegate *appDelegate = _appDelegate;
    MainPlayerController *player = _playerController;
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    // Vibe (application menu)
    NSMenu *appMenu = [VibeSubmenuItem(mainMenu, @"Vibe") submenu];
    [appMenu addItem:VibeMenuItem(@"About Vibe", @selector(showAboutWindow:), appDelegate, @"", 0, nil)];
    [appMenu addItem:[NSMenuItem separatorItem]];
    // AppKit populates the Services submenu once it's registered as
    // NSApp.servicesMenu.
    NSMenuItem *servicesItem = VibeSubmenuItem(appMenu, @"Services");
    NSApp.servicesMenu = servicesItem.submenu;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:VibeMenuItem(@"Hide Vibe", @selector(hide:), nil, @"h", NSEventModifierFlagCommand, nil)];
    [appMenu addItem:VibeMenuItem(@"Hide Others", @selector(hideOtherApplications:), nil, @"h",
                                  NSEventModifierFlagCommand | NSEventModifierFlagOption, nil)];
    [appMenu addItem:VibeMenuItem(@"Show All", @selector(unhideAllApplications:), nil, @"", 0, nil)];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:VibeMenuItem(@"Quit Vibe", @selector(terminate:), nil, @"q", NSEventModifierFlagCommand, nil)];

    // File
    NSMenu *fileMenu = [VibeSubmenuItem(mainMenu, @"File") submenu];
    [fileMenu addItem:VibeMenuItem(@"Open…", @selector(openDocument:), nil, @"o", NSEventModifierFlagCommand, nil)];
    NSMenuItem *openRecentItem = VibeSubmenuItem(fileMenu, @"Open Recent");
    _openRecentMenu = openRecentItem.submenu;
    _openRecentMenu.delegate = self; // populated from NSDocumentController on open
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:VibeMenuItem(@"Close", @selector(performClose:), nil, @"w", NSEventModifierFlagCommand, nil)];

    // Playback
    NSMenu *playbackMenu = [VibeSubmenuItem(mainMenu, @"Playback") submenu];
    [playbackMenu addItem:VibeMenuItem(@"Play", @selector(playPause:), player, @" ", 0, @"menu_play")];
    [playbackMenu addItem:VibeMenuItem(@"Previous Track", @selector(previous:), player, @"b", 0, @"menu_previous_track")];
    [playbackMenu addItem:VibeMenuItem(@"Next Track", @selector(next:), player, @"n", 0, @"menu_next_track")];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    // Bare A/S/Z/X, like the other transport keys (mask 0). Actually handled by
    // TransportKeyMonitor; the key equivalents here are for display and as the
    // fallback path. Enabled only with a track loaded (see the Menus category).
    [playbackMenu addItem:VibeMenuItem(@"Skip Forward", @selector(skipForward:), player, @"a", 0, @"menu_skip_forward")];
    [playbackMenu addItem:VibeMenuItem(@"Skip Forward More", @selector(skipForwardMore:), player, @"s", 0, @"menu_skip_forward_more")];
    [playbackMenu addItem:VibeMenuItem(@"Skip Forward Most", @selector(skipForwardMost:), player, @"d", 0, @"menu_skip_forward_most")];
    [playbackMenu addItem:VibeMenuItem(@"Skip Back", @selector(skipBack:), player, @"z", 0, @"menu_skip_back")];
    [playbackMenu addItem:VibeMenuItem(@"Skip Back More", @selector(skipBackMore:), player, @"x", 0, @"menu_skip_back_more")];
    [playbackMenu addItem:VibeMenuItem(@"Skip Back Most", @selector(skipBackMost:), player, @"c", 0, @"menu_skip_back_most")];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    // Bare Q (mask 0), handled by TransportKeyMonitor like the keys above.
    [playbackMenu addItem:VibeMenuItem(@"Low Kill", @selector(toggleLowKill:), player, @"q", 0, @"menu_low_kill")];
    NSMenu *pitchRangeMenu = [VibeSubmenuItem(playbackMenu, @"Pitch Range") submenu];
    [pitchRangeMenu addItem:VibeMenuItem(@"8%", @selector(setPitchRange:), player, @"", 0, @"pitch_range_8")];
    [pitchRangeMenu addItem:VibeMenuItem(@"16%", @selector(setPitchRange:), player, @"", 0, @"pitch_range_16")];

    // View
    NSMenu *viewMenu = [VibeSubmenuItem(mainMenu, @"View") submenu];
    NSMenu *appearanceMenu = [VibeSubmenuItem(viewMenu, @"Appearance") submenu];
    [appearanceMenu addItem:VibeMenuItem(@"System default", @selector(setAppearance:), player, @"", 0, @"view_appearance_system_default")];
    [appearanceMenu addItem:VibeMenuItem(@"Light", @selector(setAppearance:), player, @"", 0, @"view_appearance_light")];
    [appearanceMenu addItem:VibeMenuItem(@"Dark", @selector(setAppearance:), player, @"", 0, @"view_appearance_dark")];
    NSMenu *styleMenu = [VibeSubmenuItem(viewMenu, @"Style") submenu];
    styleMenu.identifier = @"waveform_style";
    styleMenu.autoenablesItems = NO;
    styleMenu.delegate = player; // fills in the renderer styles
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItem:VibeMenuItem(@"Show Playlist", @selector(toggleSize:), player,
                                   [NSString stringWithFormat:@"%c", NSTabCharacter], 0, @"menu_show_playlist")];
    [viewMenu addItem:VibeMenuItem(@"Show Pitch Control", @selector(togglePitchPanel:), player, @"p", 0, @"menu_show_pitch")];

    // Output
    NSMenu *outputMenu = [VibeSubmenuItem(mainMenu, @"Output") submenu];
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list

    NSApp.mainMenu = mainMenu;
}

// Open Recent, rebuilt from NSDocumentController each time it opens.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _openRecentMenu) {
        return;
    }
    [menu removeAllItems];
    NSArray<NSURL *> *urls = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    for (NSURL *url in urls) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:url.lastPathComponent
                                                      action:@selector(openRecentDocument:)
                                               keyEquivalent:@""];
        item.target = _appDelegate;
        item.representedObject = url;
        [menu addItem:item];
    }
    if (urls.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear Menu"
                                                   action:@selector(clearRecentDocuments:)
                                            keyEquivalent:@""];
    clear.target = [NSDocumentController sharedDocumentController];
    [menu addItem:clear];
}

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate: — a full
// Open Recent rebuild — on every keyDown (same pattern as
// OutputDevicesMenuController). No Open Recent item carries a key equivalent.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

@end
