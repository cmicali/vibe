//
//  MainMenuBuilder.m
//  Vibe
//

#import <Carbon/Carbon.h> // kTISNotifySelectedKeyboardInputSourceChanged
#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Convert.h"
#import "MainPlayerController+Playlist.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "MenuValidationRules.h"
#import "OpenRecentMenuController.h"
#import "OutputDevicesMenuController.h"
#import "SettingsRules.h"
#import "MenuShortcutRules.h"
#import "ShortcutLayout.h"
#import "VibeStrings.h"

#if VIBE_DIRECT_DISTRIBUTION
#import "VibeUpdater.h"
#endif

// TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to
// any menu it takes for Edit, of no use in the app's few short text fields.
// No public opt-out covers AutoFill, so this delegate drops every item
// without a menu_edit* identifier, separators included. It deliberately
// does not implement menuHasKeyEquivalent:…: Edit carries real key
// equivalents, which that override would answer for instead of letting
// AppKit walk the items.
@interface VibeEditMenuCleaner : NSObject <NSMenuDelegate>
@end

@implementation VibeEditMenuCleaner

- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *item in [menu.itemArray copy]) {
        if (!VibeEditMenuKeepsItem(item.identifier)) {
            [menu removeItem:item];
        }
    }
}

@end

@implementation MainMenuBuilder

static NSMenuItem *Item(NSString *title, SEL action, id target, NSString *key,
                                NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    // TRAP: NSMenuItem defaults to Command; a bare key needs an explicit 0.
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    item.identifier = identifier;
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

static NSMenuItem *AddSeparator(NSMenu *parent) {
    NSMenuItem *item = [NSMenuItem separatorItem];
    [parent addItem:item];
    return item;
}

#pragma mark - Context menus

+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(id)target
                         identifier:(NSString *)identifier {
    NSMenuItem *item = Item(title, action, target, @"", 0, identifier);
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
    return item;
}

+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)player
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    VibeShortcutSetKeyNames(STR_SETTINGS_SHORTCUTS_KEY_SPACE, STR_SETTINGS_SHORTCUTS_KEY_KEYPAD,
                            STR_SETTINGS_SHORTCUTS_KEY_UNKNOWN, STR_SETTINGS_SHORTCUTS_UNASSIGNED);
    // Never drawn: the root menu's title isn't rendered anywhere.
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Main Menu")];

    // Apple's order: App, File, Edit, View, the app's own menus, Window.
    [self buildAppMenuIn:mainMenu appDelegate:appDelegate];
    [self buildFileMenuIn:mainMenu appDelegate:appDelegate player:player
            openRecentMenuController:openRecentMenuController];
    [self buildEditMenuIn:mainMenu player:player];
    [self buildViewMenuIn:mainMenu player:player];
    [self buildPlaybackMenuIn:mainMenu player:player];
    [self buildFXMenuIn:mainMenu player:player];
    [self buildConvertMenuIn:mainMenu player:player];
    [self buildOutputMenuIn:mainMenu player:player];
    [self buildWindowMenuIn:mainMenu player:player];

    NSApp.mainMenu = mainMenu;

    // The key equivalents come after launch (AppDelegate). The first frame
    // draws the drop hint, which names Open's shortcut.
    [player applyOpenShortcutHint];
    // Labels and key equivalents follow the layout. The menu outlives this
    // observer's owner question: both last the process.
    __weak MainPlayerController *weakPlayer = player;
    [NSDistributedNotificationCenter.defaultCenter
            addObserverForName:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        VibeShortcutForgetLayout();
        [weakPlayer applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
    }];
}

+ (void)buildAppMenuIn:(NSMenu *)mainMenu appDelegate:(AppDelegate *)appDelegate {
    NSString *appName = VibeAppName();
    // macOS draws CFBundleName for the first menu whatever the title.
    NSMenu *appMenu = Submenu(mainMenu, appName).submenu;
    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_ABOUT, appName],
            @selector(showAboutWindow:), appDelegate, @"", 0, nil);
#if VIBE_DIRECT_DISTRIBUTION
    // Compiled out of the Mac App Store build, never hidden: App Review
    // rejects an app that updates itself (guideline 2.4.5).
    AddItem(appMenu, STR_MENU_APP_CHECK_FOR_UPDATES, @selector(checkForUpdates:),
            appDelegate.updater.controller, @"", 0, @"menu_check_for_updates");
#endif
    // There is no Help menu: the app ships no help book, and this was its
    // one item.
    AddItem(appMenu, STR_MENU_APP_SEND_FEEDBACK, @selector(showSupportPage:), appDelegate, @"", 0,
            @"menu_send_feedback");
    AddSeparator(appMenu);

    AddItem(appMenu, STR_MENU_APP_SETTINGS, @selector(showSettingsWindow:), appDelegate, @",",
            NSEventModifierFlagCommand, @"menu_settings");
    AddSeparator(appMenu);

    // AppKit populates the Services submenu, but not its title.
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
}

+ (void)buildFileMenuIn:(NSMenu *)mainMenu appDelegate:(AppDelegate *)appDelegate
                 player:(MainPlayerController *)player
        openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
    AddItem(fileMenu, STR_MENU_FILE_OPEN, @selector(openDocument:), appDelegate, @"", 0, kVibeMenuOpen);
    AddItem(fileMenu, STR_MENU_FILE_ADD_TO_PLAYLIST, @selector(addToPlaylist:), appDelegate, @"", 0, kVibeMenuAddToPlaylist);
    AddItem(fileMenu, STR_MENU_FILE_OPEN_LOCATION, @selector(openLink:), appDelegate, @"", 0, kVibeMenuOpenLink);
    NSMenuItem *openRecentItem = Submenu(fileMenu, STR_MENU_FILE_OPEN_RECENT);
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    AddSeparator(fileMenu);
    AddItem(fileMenu, STR_MENU_FILE_SAVE_PLAYLIST, @selector(savePlaylist:), player, @"", 0, kVibeMenuSavePlaylist);
    AddSeparator(fileMenu);
    // The file commands, in the Finder's order. Show in Finder acts on the
    // current track; Move to Trash on the selected rows.
    AddItem(fileMenu, STR_MENU_SHOW_IN_FINDER, @selector(showInFinder:), player, @"", 0, kVibeMenuShowInFinder);
    AddItem(fileMenu, STR_MENU_EDIT_MOVE_TO_TRASH, @selector(moveToTrash:), player, @"", 0,
            kVibeMenuEditMoveToTrash);
    AddSeparator(fileMenu);
    // Nil-targeted so ⌘W follows the key window; Settings and About close
    // themselves.
    AddItem(fileMenu, STR_MENU_FILE_CLOSE, @selector(closeFile:), nil, @"w", NSEventModifierFlagCommand, kVibeMenuClose);
}

+ (void)buildEditMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenuItem *editItem = Submenu(mainMenu, STR_MENU_EDIT);
    NSMenu *editMenu = editItem.submenu;
    // The delegate is weak; the Edit item retains its cleaner.
    VibeEditMenuCleaner *editMenuCleaner = [VibeEditMenuCleaner new];
    editItem.representedObject = editMenuCleaner;
    editMenu.delegate = editMenuCleaner;
    AddItem(editMenu, STR_MENU_EDIT_UNDO, @selector(undo:), nil, @"z", NSEventModifierFlagCommand, kVibeMenuEditUndo);
    // ⇧⌘Z rides in the capital letter, as VibeShortcutKeyEquivalent explains.
    AddItem(editMenu, STR_MENU_EDIT_REDO, @selector(redo:), nil, @"Z", NSEventModifierFlagCommand, kVibeMenuEditRedo);
    AddSeparator(editMenu).identifier = @"menu_edit_separator";

    // Cut and Paste are nil-targeted, so they reach the focused text field
    // and stay disabled anywhere else. Copy is the player's: it copies the
    // current track's file, and forwards to a focused text field itself.
    AddItem(editMenu, STR_MENU_EDIT_CUT, @selector(cut:), nil, @"x", NSEventModifierFlagCommand, kVibeMenuEditCut);
    AddItem(editMenu, STR_MENU_EDIT_COPY, @selector(copyFile:), player, @"c", NSEventModifierFlagCommand, kVibeMenuEditCopyFile);
    AddItem(editMenu, STR_MENU_EDIT_COPY_NAME, @selector(copyName:), player, @"", 0, kVibeMenuEditCopyName);
    AddItem(editMenu, STR_MENU_EDIT_PASTE, @selector(paste:), nil, @"v", NSEventModifierFlagCommand, kVibeMenuEditPaste);

    AddSeparator(editMenu).identifier = @"menu_edit_separator_remove";
    AddItem(editMenu, STR_MENU_EDIT_REMOVE_FROM_PLAYLIST, @selector(removeSelectedPlaylistTracks:), player, @"", 0,
            kVibeMenuEditRemoveFromPlaylist);

    AddSeparator(editMenu).identifier = @"menu_edit_separator_select";
    // Nil-targeted so ⌘A reaches whichever list has focus — the playlist, or
    // Settings > Files' granted folders. Without an item carrying ⌘A nothing
    // sends selectAll:; NSTableView never claims it itself.
    AddItem(editMenu, STR_MENU_EDIT_SELECT_ALL, @selector(selectAll:), nil, @"a", NSEventModifierFlagCommand,
            @"menu_edit_select_all");
}

+ (void)buildViewMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenu *viewMenu = Submenu(mainMenu, STR_MENU_VIEW).submenu;
    // Validation retitles both Show/Hide.
    AddItem(viewMenu, STR_MENU_VIEW_PLAYLIST, @selector(toggleSize:), player, @"", 0, kVibeMenuShowPlaylist);
    AddItem(viewMenu, STR_MENU_VIEW_PITCH_CONTROL, @selector(togglePitchPanel:), player, @"", 0, kVibeMenuShowPitch);
    AddSeparator(viewMenu);

    NSMenu *themeMenu = Submenu(viewMenu, STR_MENU_VIEW_THEME).submenu;
    themeMenu.identifier = kVibeMenuThemeSubmenu;
    themeMenu.autoenablesItems = NO;
    themeMenu.delegate = player; // fills in the themes and the Edit tail
}

+ (void)buildPlaybackMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Every shortcut here is applyShortcuts'; the bare keys are display and
    // fallback only, since TransportKeyMonitor handles the presses.
    NSMenu *playbackMenu = Submenu(mainMenu, STR_MENU_PLAYBACK).submenu;
    AddItem(playbackMenu, STR_TRANSPORT_PLAY, @selector(playPause:), player, @"", 0, kVibeMenuPlay);
    AddItem(playbackMenu, STR_TRANSPORT_PREVIOUS, @selector(previous:), player, @"", 0, kVibeMenuPreviousTrack);
    AddItem(playbackMenu, STR_TRANSPORT_NEXT, @selector(next:), player, @"", 0, kVibeMenuNextTrack);
    AddItem(playbackMenu, STR_MENU_PLAY_SELECTED, @selector(playSelectedTrack:), player, @"", 0, kVibeMenuPlaySelected);
    AddSeparator(playbackMenu);

    AddItem(playbackMenu, STR_TRANSPORT_SHUFFLE, @selector(toggleShuffle:), player, @"", 0, kVibeMenuShuffle);
    // One radio-marked item per mode. The submenu's own item carries the
    // cycling command's identifier for the Shortcuts pane; its ⌘R is the key
    // monitor's alone, since a submenu item performs nothing.
    NSMenuItem *repeatItem = Submenu(playbackMenu, STR_MENU_REPEAT);
    repeatItem.identifier = kVibeMenuRepeat;
    AddItem(repeatItem.submenu, STR_MENU_REPEAT_OFF, @selector(selectRepeatMode:), player, @"", 0,
            VibeRepeatMenuIdentifier(VibeRepeatModeOff));
    AddItem(repeatItem.submenu, STR_MENU_REPEAT_ALL, @selector(selectRepeatMode:), player, @"", 0,
            VibeRepeatMenuIdentifier(VibeRepeatModeAll));
    AddItem(repeatItem.submenu, STR_MENU_REPEAT_ONE, @selector(selectRepeatMode:), player, @"", 0,
            VibeRepeatMenuIdentifier(VibeRepeatModeOne));
    AddSeparator(playbackMenu);

    // Back before forward, as Previous and Next. Validation names each
    // distance from the track's tempo; the seconds form is the placeholder.
    NSInteger baseBars = AppSettings.sharedInstance.skipBaseBars;
    NSMenu *skipBackMenu = Submenu(playbackMenu, STR_MENU_SKIP_BACK).submenu;
    AddItem(skipBackMenu, VibeSkipMenuTitle(kVibeMenuSkipBack, baseBars, NO), @selector(skipBack:), player, @"", 0, kVibeMenuSkipBack);
    AddItem(skipBackMenu, VibeSkipMenuTitle(kVibeMenuSkipBackMore, baseBars, NO), @selector(skipBackMore:), player, @"", 0, kVibeMenuSkipBackMore);
    AddItem(skipBackMenu, VibeSkipMenuTitle(kVibeMenuSkipBackMost, baseBars, NO), @selector(skipBackMost:), player, @"", 0, kVibeMenuSkipBackMost);
    NSMenu *skipForwardMenu = Submenu(playbackMenu, STR_MENU_SKIP_FORWARD).submenu;
    AddItem(skipForwardMenu, VibeSkipMenuTitle(kVibeMenuSkipForward, baseBars, NO), @selector(skipForward:), player, @"", 0, kVibeMenuSkipForward);
    AddItem(skipForwardMenu, VibeSkipMenuTitle(kVibeMenuSkipForwardMore, baseBars, NO), @selector(skipForwardMore:), player, @"", 0, kVibeMenuSkipForwardMore);
    AddItem(skipForwardMenu, VibeSkipMenuTitle(kVibeMenuSkipForwardMost, baseBars, NO), @selector(skipForwardMost:), player, @"", 0, kVibeMenuSkipForwardMost);
    AddSeparator(playbackMenu);

    NSMenu *pitchRangeMenu = Submenu(playbackMenu, STR_MENU_PITCH_RANGE).submenu;
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_8, @selector(setPitchRange:), player, @"", 0, kVibeMenuPitchRange8);
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_16, @selector(setPitchRange:), player, @"", 0, kVibeMenuPitchRange16);
}

+ (void)buildFXMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Only TransportKeyMonitor can tell a tap (latch) from a hold (momentary).
    NSMenuItem *fxItem = Submenu(mainMenu, STR_MENU_FX);
    fxItem.identifier = @"menu_fx";
    NSMenu *fxMenu = fxItem.submenu;
    AddItem(fxMenu, STR_MENU_FX_LOW_KILL, @selector(toggleLowKill:), player, @"", 0, kVibeMenuFXLowKill);
    AddItem(fxMenu, STR_MENU_FX_LOW_KILL_BOOST, @selector(toggleLowKillBoost:), player, @"", 0, kVibeMenuFXLowKillBoost);
    AddSeparator(fxMenu);
    AddItem(fxMenu, STR_MENU_FX_REVERB, @selector(toggleReverbSend:), player, @"", 0, kVibeMenuFXReverb);
    AddItem(fxMenu, STR_MENU_FX_DELAY_8, @selector(toggleDelaySend:), player, @"", 0, kVibeMenuFXDelay);
    AddItem(fxMenu, STR_MENU_FX_DELAY_16, @selector(toggleShortDelaySend:), player, @"", 0, kVibeMenuFXShortDelay);
    fxItem.hidden = !AppSettings.sharedInstance.audioFXAllowed;
}

+ (void)buildWindowMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenu *windowMenu = Submenu(mainMenu, STR_MENU_WINDOW).submenu;
    // Nil-targeted so ⌘M follows the key window. MainWindow answers
    // performMiniaturize: itself, having no title bar button to press.
    AddItem(windowMenu, STR_WINDOW_MINIMIZE, @selector(performMiniaturize:), nil, @"m", NSEventModifierFlagCommand, nil);
    AddSeparator(windowMenu);

    // Body widths only; the height belongs to Show Playlist and the resize
    // handle.
    NSMenu *sizeMenu = Submenu(windowMenu, STR_MENU_VIEW_SIZE).submenu;
    AddItem(sizeMenu, STR_MENU_SIZE_SMALL, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall));
    AddItem(sizeMenu, STR_MENU_SIZE_DEFAULT, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetDefault));
    AddItem(sizeMenu, STR_MENU_SIZE_LARGE, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge));
    AddItem(windowMenu, STR_MENU_VIEW_ALWAYS_ON_TOP, @selector(toggleAlwaysOnTop:), player, @"", 0, kVibeMenuAlwaysOnTop);
    AddItem(windowMenu, STR_MENU_VIEW_LOCK_WINDOW_POSITION, @selector(toggleWindowPositionLock:), player, @"", 0,
            kVibeMenuLockWindowPosition);
    AddSeparator(windowMenu);

    AddItem(windowMenu, STR_MENU_WINDOW_BRING_ALL_TO_FRONT, @selector(arrangeInFront:), nil, @"", 0, nil);
    // AppKit appends the window list.
    NSApp.windowsMenu = windowMenu;
}

+ (void)buildConvertMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Always built, hidden in place by its settings effect. Validation also
    // hides the item for a file under a remote root, as it does the
    // window-body item's.
    NSMenuItem *convertItem = Submenu(mainMenu, STR_MENU_CONVERT);
    convertItem.identifier = @"menu_convert";
    AddItem(convertItem.submenu, STR_MENU_CONVERT_TO_FLAC, @selector(convertCurrentTrackToFLAC:), player, @"", 0,
            kVibeMenuConvertToFLAC);
    AddSeparator(convertItem.submenu);
    AddItem(convertItem.submenu, STR_MENU_CONVERT_TRASH_ORIGINAL, @selector(toggleDeleteOriginalAfterConvert:), player,
            @"", 0, kVibeMenuConvertDeleteOriginal);
    convertItem.hidden = !AppSettings.sharedInstance.convertEnabled;
}

+ (void)buildOutputMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Top level, for quick access while playing.
    NSMenu *outputMenu = Submenu(mainMenu, STR_MENU_OUTPUT).submenu;
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list
}

// The ConvertMenu and FX settings effects' hooks. Each menu is always built
// and hidden in place, and each call re-applies the shortcuts, which a
// hidden menu withdraws.
+ (void)applyConvertMenuVisibility {
    [self mainMenuItemWithIdentifier:@"menu_convert"].hidden = !AppSettings.sharedInstance.convertEnabled;
    [self applyShortcuts];
}

+ (void)applyFXMenuVisibility {
    [self mainMenuItemWithIdentifier:@"menu_fx"].hidden = !AppSettings.sharedInstance.audioFXAllowed;
    [self applyShortcuts];
}

#pragma mark - Shortcuts

static NSMenuItem *ItemWithIdentifier(NSMenu *menu, NSString *identifier) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:identifier]) {
            return item;
        }
        NSMenuItem *found = item.submenu ? ItemWithIdentifier(item.submenu, identifier) : nil;
        if (found) {
            return found;
        }
    }
    return nil;
}

static void ApplyShortcut(NSMenuItem *item, VibeShortcut shortcut) {
    NSEventModifierFlags mask = 0;
    NSString *equivalent = VibeShortcutKeyEquivalent(shortcut, &mask);
    // A key the layout cannot name gets no equivalent; the monitor still
    // matches the key in the player window.
    item.keyEquivalent = equivalent ?: @"";
    item.keyEquivalentModifierMask = mask;
    if (equivalent) {
        // A key-code shortcut's character is already the layout's; AppKit
        // must not localize it again. A character default localizes as any
        // app's ⌘O.
        item.allowsAutomaticKeyEquivalentLocalization = VibeShortcutIsCharacter(shortcut);
    }
}

// Cached, since the key monitor asks per keypress: the items it names are
// built once and only ever retitled or hidden. Weak values, so an item a
// menu drops is walked for again.
+ (nullable NSMenuItem *)mainMenuItemWithIdentifier:(NSString *)identifier {
    static NSMapTable<NSString *, NSMenuItem *> *items;
    if (!items) {
        items = [NSMapTable strongToWeakObjectsMapTable];
    }
    NSMenuItem *item = [items objectForKey:identifier];
    if (!item) {
        item = ItemWithIdentifier(NSApp.mainMenu, identifier);
        if (item) {
            [items setObject:item forKey:identifier];
        }
    }
    return item;
}

static NSString *ShortcutLabel(NSMenuItem *item) {
    NSString *identifier = item.identifier;
    if ([identifier isEqualToString:kVibeMenuPlay]) {
        return STR_SETTINGS_SHORTCUTS_PLAY_PAUSE;
    }
    if ([identifier isEqualToString:kVibeMenuConvertToFLAC]) {
        return VibeConvertMenuTitle(NO);
    }
    NSString *title = VibeSkipMenuTitle(identifier, AppSettings.sharedInstance.skipBaseBars, YES) ?: item.title;
    NSMenu *parent = item.menu.supermenu;
    if (parent && parent != NSApp.mainMenu) {
        NSInteger index = [parent indexOfItemWithSubmenu:item.menu];
        if (index >= 0) {
            return [NSString stringWithFormat:STR_SETTINGS_SHORTCUTS_SUBMENU_ITEM,
                                              [parent itemAtIndex:index].title, title];
        }
    }
    return title;
}

static void CollectShortcutRows(NSMenu *menu, NSMutableArray<NSArray *> *rows) {
    for (NSMenuItem *item in menu.itemArray) {
        // Repeat is a submenu whose own item is the cycling command.
        if (item.identifier && [VibeShortcutIdentifiers() containsObject:item.identifier]) {
            [rows addObject:@[item.identifier, ShortcutLabel(item)]];
        }
        if (item.submenu) {
            CollectShortcutRows(item.submenu, rows);
        }
    }
}

+ (NSArray<NSArray *> *)shortcutCommandRows {
    NSMutableArray<NSArray *> *groups = [NSMutableArray array];
    for (NSMenuItem *topLevel in NSApp.mainMenu.itemArray) {
        NSMutableArray<NSArray *> *rows = [NSMutableArray array];
        CollectShortcutRows(topLevel.submenu, rows);
        if (rows.count) {
            [groups addObject:@[topLevel.title, rows]];
        }
    }
    return groups;
}

+ (void)applyShortcuts {
    NSDictionary *overrides = AppSettings.sharedInstance.shortcutOverrides;
    for (NSString *identifier in VibeShortcutIdentifiers()) {
        NSMenuItem *item = [self mainMenuItemWithIdentifier:identifier];
        // Repeat's submenu item carries its identifier for the Shortcuts pane
        // and nothing else: AppKit performs no action for a submenu's item.
        if (item.hasSubmenu) {
            continue;
        }
        // TRAP: hiding a submenu does not deactivate its key equivalents (FX
        // and Convert hide in place), so an item under a hidden menu gets
        // none. Not the item's own flag, which Convert's validation sets and
        // may not have cleared yet.
        ApplyShortcut(item, item.parentItem.isHiddenOrHasHiddenAncestor
                ? kVibeShortcutNone : [self carriedShortcutForIdentifier:identifier overrides:overrides]);
    }
}

+ (VibeShortcut)carriedShortcutForIdentifier:(NSString *)identifier overrides:(NSDictionary *)overrides {
    VibeShortcut shortcut = VibeShortcutEffective(VibeShortcutTable(), identifier, overrides);
    if (shortcut == kVibeShortcutNone) {
        return kVibeShortcutNone;
    }
    unsigned short key = VibeShortcutKey(shortcut);
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    BOOL isCharacter = VibeShortcutIsCharacter(shortcut);
    unsigned short layoutKeyCode = isCharacter ? VibeShortcutKeyCodeForCharacter(key, modifiers) : kVibeShortcutKeyMask;
    unichar layoutCharacter = isCharacter
            ? 0 : VibeShortcutCharacterForKeyCode(VibeShortcutCanonicalKeyCode(key), modifiers);
    return VibeShortcutForMenuItem(VibeShortcutTable(), identifier, shortcut, layoutKeyCode, layoutCharacter, overrides);
}

@end
