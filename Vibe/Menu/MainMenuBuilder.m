//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Transport.h"
#import "OpenRecentMenuController.h"
#import "OutputDevicesMenuController.h"

@implementation MainMenuBuilder

static NSMenuItem *VibeMenuItem(NSString *title, SEL action, id target, NSString *key,
                                NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    // NSMenuItem defaults to a Command modifier; the transport keys are bare
    // so the mask must be set explicitly every time.
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    item.identifier = identifier;
    return item;
}

// Same, plus a system-symbol icon.
static NSMenuItem *VibeSymbolMenuItem(NSString *title, NSString *symbolName, SEL action, id target,
                                      NSString *key, NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = VibeMenuItem(title, action, target, key, modifiers, identifier);
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
    return item;
}

static NSMenuItem *VibeSubmenuItem(NSMenu *parent, NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    item.submenu = [[NSMenu alloc] initWithTitle:title];
    [parent addItem:item];
    return item;
}

+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)player
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
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
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    [fileMenu addItem:[NSMenuItem separatorItem]];
    // Closes the loaded file(s), not the window; title/enabled state managed
    // by validation.
    [fileMenu addItem:VibeSymbolMenuItem(@"Close File", @"xmark", @selector(closeFile:), player, @"w", NSEventModifierFlagCommand, @"menu_close")];

    // Playback
    NSMenu *playbackMenu = [VibeSubmenuItem(mainMenu, @"Playback") submenu];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Play", @"play.fill", @selector(playPause:), player, @" ", 0, @"menu_play")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Previous Track", @"backward.end.fill", @selector(previous:), player, @"b", 0, @"menu_previous_track")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Next Track", @"forward.end.fill", @selector(next:), player, @"n", 0, @"menu_next_track")];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    // Bare A/S/D/Z/X/C, like the other transport keys (mask 0). Actually handled by
    // TransportKeyMonitor; the key equivalents here are for display and as the
    // fallback path. Enabled only with a track loaded (see the Menus category).
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Forward", @"forward", @selector(skipForward:), player, @"a", 0, @"menu_skip_forward")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Forward More", @"", @selector(skipForwardMore:), player, @"s", 0, @"menu_skip_forward_more")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Forward Most", @"", @selector(skipForwardMost:), player, @"d", 0, @"menu_skip_forward_most")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Back", @"backward", @selector(skipBack:), player, @"z", 0, @"menu_skip_back")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Back More", @"", @selector(skipBackMore:), player, @"x", 0, @"menu_skip_back_more")];
    [playbackMenu addItem:VibeSymbolMenuItem(@"Skip Back Most", @"", @selector(skipBackMost:), player, @"c", 0, @"menu_skip_back_most")];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    // Bare Q (mask 0), handled by TransportKeyMonitor like the keys above.
    [playbackMenu addItem:VibeSymbolMenuItem(@"Low Kill", @"dial.min", @selector(toggleLowKill:), player, @"q", 0, @"menu_low_kill")];
    NSMenuItem *pitchRangeItem = VibeSubmenuItem(playbackMenu, @"Pitch Range");
    pitchRangeItem.image = [NSImage imageWithSystemSymbolName:@"slider.vertical.3" accessibilityDescription:@"Pitch Range"];
    NSMenu *pitchRangeMenu = pitchRangeItem.submenu;
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
    [viewMenu addItem:VibeSymbolMenuItem(@"Show Playlist", @"list.dash", @selector(toggleSize:), player,
                                   [NSString stringWithFormat:@"%c", NSTabCharacter], 0, @"menu_show_playlist")];
    [viewMenu addItem:VibeSymbolMenuItem(@"Show Pitch Control", @"slider.vertical.3", @selector(togglePitchPanel:), player, @"p", 0, @"menu_show_pitch")];

    // Output
    NSMenu *outputMenu = [VibeSubmenuItem(mainMenu, @"Output") submenu];
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list

    NSApp.mainMenu = mainMenu;
}

@end
