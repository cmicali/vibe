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

static NSMenuItem *Item(NSString *title, SEL action, id target, NSString *key,
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
static NSMenuItem *SymbolItem(NSString *title, NSString *symbolName, SEL action, id target,
                                      NSString *key, NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = Item(title, action, target, key, modifiers, identifier);
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
    return item;
}

static NSMenuItem *Submenu(NSMenu *parent, NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    item.submenu = [[NSMenu alloc] initWithTitle:title];
    [parent addItem:item];
    return item;
}

static NSMenuItem *AddItem(NSMenu *parent, NSString *title, SEL action, id target, NSString *key,
                           NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = Item(title, action, target, key, modifiers, identifier);
    [parent addItem:item];
    return item;
}

static NSMenuItem *AddSymbolItem(NSMenu *parent, NSString *title, NSString *symbolName, SEL action,
                                 id target, NSString *key, NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = SymbolItem(title, symbolName, action, target, key, modifiers, identifier);
    [parent addItem:item];
    return item;
}

static NSMenuItem *AddSeparator(NSMenu *parent) {
    NSMenuItem *item = [NSMenuItem separatorItem];
    [parent addItem:item];
    return item;
}

+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)player
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    // Vibe (application menu)
    NSMenu *appMenu = Submenu(mainMenu, @"Vibe").submenu;
    AddItem(appMenu, @"About Vibe", @selector(showAboutWindow:), appDelegate, @"", 0, nil);
    AddSeparator(appMenu);

    // AppKit populates the Services submenu once it's registered as
    // NSApp.servicesMenu.
    NSMenuItem *servicesItem = Submenu(appMenu, @"Services");
    NSApp.servicesMenu = servicesItem.submenu;
    AddSeparator(appMenu);

    AddItem(appMenu, @"Hide Vibe", @selector(hide:), nil, @"h", NSEventModifierFlagCommand, nil);
    AddItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), nil, @"h",NSEventModifierFlagCommand | NSEventModifierFlagOption, nil);
    AddItem(appMenu, @"Show All", @selector(unhideAllApplications:), nil, @"", 0, nil);
    AddSeparator(appMenu);

    AddItem(appMenu, @"Quit Vibe", @selector(terminate:), nil, @"q", NSEventModifierFlagCommand, nil);

    // File
    NSMenu *fileMenu = Submenu(mainMenu, @"File").submenu;
    AddItem(fileMenu, @"Open…", @selector(openDocument:), nil, @"o", NSEventModifierFlagCommand, nil);
    NSMenuItem *openRecentItem = Submenu(fileMenu, @"Open Recent");
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    AddSeparator(fileMenu);
    AddSymbolItem(fileMenu, @"Close File", @"xmark", @selector(closeFile:), player, @"w", NSEventModifierFlagCommand, @"menu_close");

    // Playback
    NSMenu *playbackMenu = Submenu(mainMenu, @"Playback").submenu;
    AddSymbolItem(playbackMenu, @"Play", @"play.fill", @selector(playPause:), player, @" ", 0, @"menu_play");
    AddSymbolItem(playbackMenu, @"Previous Track", @"backward.end.fill", @selector(previous:), player, @"b", 0, @"menu_previous_track");
    AddSymbolItem(playbackMenu, @"Next Track", @"forward.end.fill", @selector(next:), player, @"n", 0, @"menu_next_track");
    AddSeparator(playbackMenu);

    // Bare A/S/D/Z/X/C, like the other transport keys (mask 0). Actually handled by
    // TransportKeyMonitor; the key equivalents here are for display and as the
    // fallback path. Enabled only with a track loaded (see the Menus category).
    AddSymbolItem(playbackMenu, @"Skip Forward", @"forward", @selector(skipForward:), player, @"a", 0, @"menu_skip_forward");
    AddSymbolItem(playbackMenu, @"Skip Forward More", @"", @selector(skipForwardMore:), player, @"s", 0, @"menu_skip_forward_more");
    AddSymbolItem(playbackMenu, @"Skip Forward Most", @"", @selector(skipForwardMost:), player, @"d", 0, @"menu_skip_forward_most");
    AddSymbolItem(playbackMenu, @"Skip Back", @"backward", @selector(skipBack:), player, @"z", 0, @"menu_skip_back");
    AddSymbolItem(playbackMenu, @"Skip Back More", @"", @selector(skipBackMore:), player, @"x", 0, @"menu_skip_back_more");
    AddSymbolItem(playbackMenu, @"Skip Back Most", @"", @selector(skipBackMost:), player, @"c", 0, @"menu_skip_back_most");
    AddSeparator(playbackMenu);

    NSMenuItem *pitchRangeItem = Submenu(playbackMenu, @"Pitch Range");
    pitchRangeItem.image = [NSImage imageWithSystemSymbolName:@"slider.vertical.3" accessibilityDescription:@"Pitch Range"];
    NSMenu *pitchRangeMenu = pitchRangeItem.submenu;
    AddItem(pitchRangeMenu, @"8%", @selector(setPitchRange:), player, @"", 0, @"pitch_range_8");
    AddItem(pitchRangeMenu, @"16%", @selector(setPitchRange:), player, @"", 0, @"pitch_range_16");

    // FX — the DJ performance effects, one item per bare key (Q/W/E/R/T,
    // mask 0). Like the skip keys, the equivalents here are for display and as
    // the fallback path; TransportKeyMonitor actually handles the presses, and
    // it alone can tell a tap (latches, like these toggles) from a hold
    // (momentary). Always enabled — they are deck controls that persist across
    // tracks and apply to whatever is, or starts, playing. Validation shows
    // each one's state as a checkmark.
    NSMenu *fxMenu = Submenu(mainMenu, @"FX").submenu;
    AddSymbolItem(fxMenu, @"Low Kill", @"dial.min", @selector(toggleLowKill:), player, @"q", 0, @"menu_fx_low_kill");
    AddSymbolItem(fxMenu, @"Low Kill Boost", @"dial.max.fill", @selector(toggleLowKillBoost:), player, @"w", 0, @"menu_fx_low_kill_boost");
    AddSeparator(fxMenu);
    AddSymbolItem(fxMenu, @"Reverb", @"water.waves", @selector(toggleReverbSend:), player, @"e", 0, @"menu_fx_reverb");
    AddSymbolItem(fxMenu, @"Delay 1/8", @"repeat", @selector(toggleDelaySend:), player, @"r", 0, @"menu_fx_delay");
    AddSymbolItem(fxMenu, @"Delay 1/16", @"repeat.circle", @selector(toggleShortDelaySend:), player, @"t", 0, @"menu_fx_short_delay");

    // View
    NSMenu *viewMenu = Submenu(mainMenu, @"View").submenu;
    AddSymbolItem(viewMenu, @"Show Playlist", @"list.dash", @selector(toggleSize:), player, [NSString stringWithFormat:@"%c", NSTabCharacter], 0, @"menu_show_playlist");
    AddSymbolItem(viewMenu, @"Show Pitch Control", @"slider.vertical.3", @selector(togglePitchPanel:), player, @"p", 0, @"menu_show_pitch");
    AddSeparator(viewMenu);

    NSMenu *appearanceMenu = Submenu(viewMenu, @"Appearance").submenu;
    AddItem(appearanceMenu, @"System default", @selector(setAppearance:), player, @"", 0, @"view_appearance_system_default");
    AddItem(appearanceMenu, @"Light", @selector(setAppearance:), player, @"", 0, @"view_appearance_light");
    AddItem(appearanceMenu, @"Dark", @selector(setAppearance:), player, @"", 0, @"view_appearance_dark");
    NSMenu *waveformMenu = Submenu(viewMenu, @"Waveform").submenu;
    waveformMenu.identifier = @"waveform_style";
    waveformMenu.autoenablesItems = NO;
    waveformMenu.delegate = player; // fills in the renderer styles


    // Output
    NSMenu *outputMenu = Submenu(mainMenu, @"Output").submenu;
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list

    NSApp.mainMenu = mainMenu;
}

@end
