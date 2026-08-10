//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Convert.h"
#import "MainPlayerController+Transport.h"
#import "OpenRecentMenuController.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"

// Strips what macOS force-appends to any menu it takes for an Edit menu —
// AutoFill, Start Dictation and Emoji & Symbols, all inert in an app with no
// text input. There is no supported opt-out: AppKit's only suppression
// defaults cover Dictation and the character palette, nothing covers
// AutoFill, so the one uniform, public-API path is a delegate that drops
// every item the builder didn't add. Ours all carry menu_edit_* identifiers;
// anything else, the system's separators included, goes. Deliberately NOT
// implementing menuHasKeyEquivalent:…, unlike the app's other menu
// delegates: this menu carries real key equivalents (⌘Z, ⇧⌘Z, ⌘C, ⇧⌘C),
// and that override would answer for them instead of letting AppKit walk
// the items.
@interface VibeEditMenuCleaner : NSObject <NSMenuDelegate>
@end

@implementation VibeEditMenuCleaner

- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *item in [menu.itemArray copy]) {
        if (![item.identifier hasPrefix:@"menu_edit"]) {
            [menu removeItem:item];
        }
    }
}

@end

@implementation MainMenuBuilder

static NSMenuItem *Item(NSString *title, SEL action, id target, NSString *key,
                                NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    // NSMenuItem defaults to a Command modifier, and the transport keys are
    // bare, so the mask must be set explicitly every time.
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    item.identifier = identifier;
    return item;
}

// The same, plus a system-symbol icon.
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
    // Never drawn: the root menu's title isn't rendered anywhere.
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Main Menu")];

    NSString *appName = VibeAppName();

    // Vibe (application menu). macOS draws CFBundleName in bold for the first
    // menu regardless of the title set here.
    NSMenu *appMenu = Submenu(mainMenu, appName).submenu;
    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_ABOUT, appName],
            @selector(showAboutWindow:), appDelegate, @"", 0, nil);
    AddSeparator(appMenu);

    // AppDelegate's validation titles and enables this. It flips to a disabled
    // "Vibe Is the Default Music Player" once there is nothing left to do.
    AddSymbolItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_MAKE_DEFAULT, appName],
                  @"app.badge.checkmark",
                  @selector(makeDefaultMusicPlayer:), appDelegate, @"", 0, @"menu_make_default_app");
    AddSeparator(appMenu);

    // AppKit populates the Services submenu once it is registered as
    // NSApp.servicesMenu — but not its title, which is ours to localize.
    NSMenuItem *servicesItem = Submenu(appMenu, STR_MENU_APP_SERVICES);
    NSApp.servicesMenu = servicesItem.submenu;
    AddSeparator(appMenu);

    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_HIDE, appName],
            @selector(hide:), nil, @"h", NSEventModifierFlagCommand, nil);
    AddItem(appMenu, STR_MENU_APP_HIDE_OTHERS, @selector(hideOtherApplications:), nil, @"h",NSEventModifierFlagCommand | NSEventModifierFlagOption, nil);
    AddItem(appMenu, STR_MENU_APP_SHOW_ALL, @selector(unhideAllApplications:), nil, @"", 0, nil);
    AddSeparator(appMenu);

    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_QUIT, appName],
            @selector(terminate:), nil, @"q", NSEventModifierFlagCommand, nil);

    // File
    NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
    AddItem(fileMenu, STR_MENU_FILE_OPEN, @selector(openDocument:), nil, @"o", NSEventModifierFlagCommand, nil);
    NSMenuItem *openRecentItem = Submenu(fileMenu, STR_MENU_FILE_OPEN_RECENT);
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    AddSeparator(fileMenu);
    AddSymbolItem(fileMenu, STR_MENU_FILE_CLOSE, @"xmark", @selector(closeFile:), player, @"w", NSEventModifierFlagCommand, @"menu_close");

    // Edit: undo and redo only — the app has no selection and no clipboard.
    // Validation retitles them from NSUndoManager.
    NSMenu *editMenu = Submenu(mainMenu, STR_MENU_EDIT).submenu;
    static VibeEditMenuCleaner *editMenuCleaner;
    editMenuCleaner = editMenuCleaner ?: [VibeEditMenuCleaner new];
    editMenu.delegate = editMenuCleaner;
    AddSymbolItem(editMenu, STR_MENU_EDIT_UNDO, @"arrow.uturn.backward", @selector(undo:), player, @"z", NSEventModifierFlagCommand, @"menu_edit_undo");
    // ⇧⌘Z — capital "Z", same contract as Copy Name's "C" below.
    AddSymbolItem(editMenu, STR_MENU_EDIT_REDO, @"arrow.uturn.forward", @selector(redo:), player, @"Z", NSEventModifierFlagCommand, @"menu_edit_redo");
    // The cleaner keeps only menu_edit_*-identified items, the separator
    // included.
    AddSeparator(editMenu).identifier = @"menu_edit_separator";

    // Copy Name copies the header's "Artist - Title" line as text; Copy File
    // puts the current track's file URL on the general pasteboard, so a
    // Finder paste duplicates the file. Copy Name's ⇧⌘ rides in the capital
    // "C", per the NSMenuItem contract — a lowercase key with Shift in the
    // mask draws right but never matches a real key press
    // (charactersIgnoringModifiers arrives uppercase).
    AddSymbolItem(editMenu, STR_MENU_EDIT_COPY_NAME, @"textformat", @selector(copyName:), player, @"C", NSEventModifierFlagCommand, @"menu_edit_copy_name");
    AddSymbolItem(editMenu, STR_MENU_EDIT_COPY_FILE, @"doc.on.doc", @selector(copyFile:), player, @"c", NSEventModifierFlagCommand, @"menu_edit_copy_file");

    // Playback
    NSMenu *playbackMenu = Submenu(mainMenu, STR_MENU_PLAYBACK).submenu;
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PLAY, @"play.fill", @selector(playPause:), player, @" ", 0, @"menu_play");
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PREVIOUS, @"backward.end.fill", @selector(previous:), player, @"b", 0, @"menu_previous_track");
    AddSymbolItem(playbackMenu, STR_TRANSPORT_NEXT, @"forward.end.fill", @selector(next:), player, @"n", 0, @"menu_next_track");
    AddSeparator(playbackMenu);

    // Bare A, S, D, Z, X and C, like the other transport keys, at mask 0.
    // TransportKeyMonitor actually handles them, and the key equivalents here
    // are for display and as the fallback path. They are enabled only with a
    // track loaded; see the Menus category.
    AddSymbolItem(playbackMenu, STR_MENU_SKIP_FORWARD, @"forward", @selector(skipForward:), player, @"a", 0, @"menu_skip_forward");
    AddItem(playbackMenu, STR_MENU_SKIP_FORWARD_MORE, @selector(skipForwardMore:), player, @"s", 0, @"menu_skip_forward_more");
    AddItem(playbackMenu, STR_MENU_SKIP_FORWARD_MOST, @selector(skipForwardMost:), player, @"d", 0, @"menu_skip_forward_most");
    AddSymbolItem(playbackMenu, STR_MENU_SKIP_BACK, @"backward", @selector(skipBack:), player, @"z", 0, @"menu_skip_back");
    AddItem(playbackMenu, STR_MENU_SKIP_BACK_MORE, @selector(skipBackMore:), player, @"x", 0, @"menu_skip_back_more");
    AddItem(playbackMenu, STR_MENU_SKIP_BACK_MOST, @selector(skipBackMost:), player, @"c", 0, @"menu_skip_back_most");
    AddSeparator(playbackMenu);

    NSString *pitchRangeTitle = STR_MENU_PITCH_RANGE;
    NSMenuItem *pitchRangeItem = Submenu(playbackMenu, pitchRangeTitle);
    pitchRangeItem.image = [NSImage imageWithSystemSymbolName:@"slider.vertical.3" accessibilityDescription:pitchRangeTitle];
    NSMenu *pitchRangeMenu = pitchRangeItem.submenu;
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_8, @selector(setPitchRange:), player, @"", 0, @"pitch_range_8");
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_16, @selector(setPitchRange:), player, @"", 0, @"pitch_range_16");

    // FX: the DJ performance effects, one item per bare key — Q, W, E, R and
    // T, at mask 0. As with the skip keys, the equivalents here are for
    // display and as the fallback path. TransportKeyMonitor actually handles
    // the presses, and it alone can tell a tap, which latches like these
    // toggles, from a hold, which is momentary. They are always enabled,
    // because they are deck controls that persist across tracks and apply to
    // whatever is playing or starts to play. Validation shows each one's state
    // as a checkmark.
    NSMenu *fxMenu = Submenu(mainMenu, STR_MENU_FX).submenu;
    AddSymbolItem(fxMenu, STR_MENU_FX_LOW_KILL, @"dial.min", @selector(toggleLowKill:), player, @"q", 0, @"menu_fx_low_kill");
    AddSymbolItem(fxMenu, STR_MENU_FX_LOW_KILL_BOOST, @"dial.max.fill", @selector(toggleLowKillBoost:), player, @"w", 0, @"menu_fx_low_kill_boost");
    AddSeparator(fxMenu);
    AddSymbolItem(fxMenu, STR_MENU_FX_REVERB, @"water.waves", @selector(toggleReverbSend:), player, @"e", 0, @"menu_fx_reverb");
    AddSymbolItem(fxMenu, STR_MENU_FX_DELAY_8, @"repeat", @selector(toggleDelaySend:), player, @"r", 0, @"menu_fx_delay");
    AddSymbolItem(fxMenu, STR_MENU_FX_DELAY_16, @"repeat.circle", @selector(toggleShortDelaySend:), player, @"t", 0, @"menu_fx_short_delay");

    // View
    NSMenu *viewMenu = Submenu(mainMenu, STR_MENU_VIEW).submenu;
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PLAYLIST, @"list.dash", @selector(toggleSize:), player, [NSString stringWithFormat:@"%c", NSTabCharacter], 0, @"menu_show_playlist");
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PITCH_CONTROL, @"slider.vertical.3", @selector(togglePitchPanel:), player, @"p", 0, @"menu_show_pitch");
    AddSeparator(viewMenu);

    // The width presets: the drag minimum, the design width, and 1.75 times
    // the design width; see setWindowSize:. The height is deliberately
    // untouched, since it belongs to Show Playlist and the resize handle.
    NSMenu *sizeMenu = Submenu(viewMenu, STR_MENU_VIEW_SIZE).submenu;
    AddItem(sizeMenu, STR_MENU_SIZE_SMALL, @selector(setWindowSize:), player, @"", 0, @"view_size_small");
    AddItem(sizeMenu, STR_MENU_SIZE_DEFAULT, @selector(setWindowSize:), player, @"", 0, @"view_size_default");
    AddItem(sizeMenu, STR_MENU_SIZE_LARGE, @selector(setWindowSize:), player, @"", 0, @"view_size_large");

    NSMenu *appearanceMenu = Submenu(viewMenu, STR_MENU_VIEW_APPEARANCE).submenu;
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_SYSTEM, @selector(setAppearance:), player, @"", 0, @"view_appearance_system_default");
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_LIGHT, @selector(setAppearance:), player, @"", 0, @"view_appearance_light");
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_DARK, @selector(setAppearance:), player, @"", 0, @"view_appearance_dark");
    NSMenu *waveformMenu = Submenu(viewMenu, STR_MENU_VIEW_WAVEFORM).submenu;
    waveformMenu.identifier = @"waveform_style";
    waveformMenu.autoenablesItems = NO;
    waveformMenu.delegate = player; // fills in the renderer styles

    // Convert
    NSMenu *convertMenu = Submenu(mainMenu, STR_MENU_CONVERT).submenu;
    // Enabled only for an uncompressed current track with no FLAC beside it
    // yet; validation retitles it with the reason otherwise.
    AddSymbolItem(convertMenu, STR_MENU_CONVERT_TO_FLAC, @"arrow.triangle.2.circlepath", @selector(convertCurrentTrackToFLAC:), player, @"", 0, @"menu_convert_to_flac");
    AddSeparator(convertMenu);
    // A checkmarked preference rather than an action, so it is always enabled.
    AddSymbolItem(convertMenu, STR_MENU_CONVERT_DELETE_ORIGINAL, @"trash", @selector(toggleDeleteOriginalAfterConvert:), player, @"", 0, @"menu_convert_delete_original");

    // Output
    NSMenu *outputMenu = Submenu(mainMenu, STR_MENU_OUTPUT).submenu;
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list

    NSApp.mainMenu = mainMenu;
}

@end
