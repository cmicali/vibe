//
//  MainMenuBuilder.m
//  Vibe
//

#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Convert.h"
#import "MainPlayerController+Transport.h"
#import "MenuValidationRules.h"
#import "OpenRecentMenuController.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"

// TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to
// any menu it takes for Edit, all inert here. No public opt-out covers
// AutoFill, so this delegate drops every item without a menu_edit* identifier,
// separators included. It deliberately does not implement
// menuHasKeyEquivalent:…: Edit carries real key equivalents, which that
// override would answer for instead of letting AppKit walk the items.
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
    // TRAP: NSMenuItem defaults to Command; a bare key needs an explicit 0.
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    item.identifier = identifier;
    return item;
}

// Symbol images wait for the first menu tracking: nothing shows them before,
// and loading forty-odd at install cost ~7 ms ahead of the first frame. Weak
// keys, so a context menu rebuilt before any menu opens drops out.
static NSMapTable<NSMenuItem *, NSString *> *sPendingSymbolItems;
static BOOL sSymbolImagesFilled;

static void SetSymbolImage(NSMenuItem *item, NSString *symbolName) {
    if (sSymbolImagesFilled) {
        item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:item.title];
        return;
    }
    if (!sPendingSymbolItems) {
        sPendingSymbolItems = [NSMapTable weakToStrongObjectsMapTable];
        __block id observer = [NSNotificationCenter.defaultCenter
                addObserverForName:NSMenuDidBeginTrackingNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            sSymbolImagesFilled = YES;
            for (NSMenuItem *pending in sPendingSymbolItems) {
                SetSymbolImage(pending, [sPendingSymbolItems objectForKey:pending]);
            }
            sPendingSymbolItems = nil;
        }];
    }
    [sPendingSymbolItems setObject:symbolName forKey:item];
}

static NSMenuItem *SymbolItem(NSString *title, NSString *symbolName, SEL action, id target,
                                      NSString *key, NSEventModifierFlags modifiers, NSString *identifier) {
    NSMenuItem *item = Item(title, action, target, key, modifiers, identifier);
    SetSymbolImage(item, symbolName);
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

static NSMenuItem *AddFXItem(NSMenu *parent, NSString *title, NSString *symbolName, SEL action,
                             id target, NSString *key, NSString *identifier) {
    NSMenuItem *item = AddSymbolItem(parent, title, symbolName, action, target, key, 0, identifier);
    // The shortcut applyFXMenuVisibility: restores.
    item.representedObject = key;
    return item;
}

static NSMenuItem *TopLevelMenuItemWithIdentifier(NSString *identifier) {
    for (NSMenuItem *item in NSApp.mainMenu.itemArray) {
        if ([item.identifier isEqualToString:identifier]) {
            return item;
        }
    }
    return nil;
}

static NSMenuItem *AddSeparator(NSMenu *parent) {
    NSMenuItem *item = [NSMenuItem separatorItem];
    [parent addItem:item];
    return item;
}

#pragma mark - Items shared with context menus

+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(id)target
                         identifier:(NSString *)identifier {
    return SymbolItem(title, symbolName, action, target, @"", 0, identifier);
}

+ (NSMenuItem *)copyNameItemWithTarget:(id)target {
    return SymbolItem(STR_MENU_EDIT_COPY_NAME, @"textformat", @selector(copyName:),
                      target, @"", 0, kVibeMenuEditCopyName);
}

+ (NSMenuItem *)copyFileItemWithTarget:(id)target {
    return SymbolItem(STR_MENU_EDIT_COPY_FILE, @"doc.on.doc", @selector(copyFile:),
                      target, @"", 0, kVibeMenuEditCopyFile);
}

+ (NSMenuItem *)convertToFLACItemWithTarget:(id)target {
    return SymbolItem(STR_MENU_CONVERT_TO_FLAC, @"arrow.triangle.2.circlepath",
                      @selector(convertCurrentTrackToFLAC:), target, @"", 0, kVibeMenuConvertToFLAC);
}

+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)player
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    // Never drawn: the root menu's title isn't rendered anywhere.
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Main Menu")];

    [self buildAppMenuIn:mainMenu appDelegate:appDelegate];
    [self buildFileMenuIn:mainMenu player:player openRecentMenuController:openRecentMenuController];
    [self buildEditMenuIn:mainMenu player:player];
    [self buildPlaybackMenuIn:mainMenu player:player];
    [self buildFXMenuIn:mainMenu player:player];
    [self buildViewMenuIn:mainMenu player:player];
    [self buildConvertMenuIn:mainMenu player:player];
    [self buildOutputMenuIn:mainMenu player:player];
    [self buildHelpMenuIn:mainMenu appDelegate:appDelegate];

    NSApp.mainMenu = mainMenu;
}

+ (void)buildAppMenuIn:(NSMenu *)mainMenu appDelegate:(AppDelegate *)appDelegate {
    NSString *appName = VibeAppName();
    // macOS draws CFBundleName for the first menu whatever the title.
    NSMenu *appMenu = Submenu(mainMenu, appName).submenu;
    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_ABOUT, appName],
            @selector(showAboutWindow:), appDelegate, @"", 0, nil);
    AddSeparator(appMenu);

    AddSymbolItem(appMenu, STR_MENU_APP_SETTINGS, @"gearshape",
                  @selector(showSettingsWindow:), appDelegate, @",", NSEventModifierFlagCommand, @"menu_settings");
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

+ (void)buildFileMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player
        openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
    AddItem(fileMenu, STR_MENU_FILE_OPEN, @selector(openDocument:), nil, @"o", NSEventModifierFlagCommand, nil);
    NSMenuItem *openRecentItem = Submenu(fileMenu, STR_MENU_FILE_OPEN_RECENT);
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    AddSeparator(fileMenu);
    AddSymbolItem(fileMenu, STR_MENU_FILE_SAVE_PLAYLIST, @"square.and.arrow.down", @selector(savePlaylist:), player, @"s", NSEventModifierFlagCommand, kVibeMenuSavePlaylist);
    AddSeparator(fileMenu);
    // Nil-targeted so ⌘W follows the key window; Settings and About close
    // themselves.
    AddSymbolItem(fileMenu, STR_MENU_FILE_CLOSE, @"xmark", @selector(closeFile:), nil, @"w", NSEventModifierFlagCommand, kVibeMenuClose);
}

+ (void)buildEditMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenuItem *editItem = Submenu(mainMenu, STR_MENU_EDIT);
    NSMenu *editMenu = editItem.submenu;
    // The delegate is weak; the Edit item retains its cleaner.
    VibeEditMenuCleaner *editMenuCleaner = [VibeEditMenuCleaner new];
    editItem.representedObject = editMenuCleaner;
    editMenu.delegate = editMenuCleaner;
    AddSymbolItem(editMenu, STR_MENU_EDIT_UNDO, @"arrow.uturn.backward", @selector(undo:), nil, @"z", NSEventModifierFlagCommand, kVibeMenuEditUndo);
    // ⇧⌘Z: capital "Z", as Copy Name's "C" below.
    AddSymbolItem(editMenu, STR_MENU_EDIT_REDO, @"arrow.uturn.forward", @selector(redo:), nil, @"Z", NSEventModifierFlagCommand, kVibeMenuEditRedo);
    AddSeparator(editMenu).identifier = @"menu_edit_separator";

    // TRAP: a shifted equivalent rides in the capital letter ("C" with Command
    // is ⇧⌘C). A lowercase key with Shift in the mask draws right but never
    // matches a real press.
    NSMenuItem *copyNameItem = [self copyNameItemWithTarget:player];
    copyNameItem.keyEquivalent = @"C";
    copyNameItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [editMenu addItem:copyNameItem];
    NSMenuItem *copyFileItem = [self copyFileItemWithTarget:player];
    copyFileItem.keyEquivalent = @"c";
    copyFileItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [editMenu addItem:copyFileItem];

    AddSeparator(editMenu).identifier = @"menu_edit_separator_remove";
    // minus.circle, not trash: the file stays on disk. NSBackspaceCharacter
    // draws as ⌫, but a real press delivers NSDeleteCharacter, so
    // TransportKeyMonitor handles it, and Forward Delete.
    AddSymbolItem(editMenu, STR_MENU_EDIT_REMOVE_FROM_PLAYLIST, @"minus.circle",
                  @selector(removeSelectedPlaylistTracks:), player,
                  [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter], 0,
                  kVibeMenuEditRemoveFromPlaylist);

    AddSeparator(editMenu).identifier = @"menu_edit_separator_select";
    // Nil-targeted so ⌘A reaches whichever list has focus — the playlist, or
    // Settings > Files' granted folders. Without an item carrying ⌘A nothing
    // sends selectAll:; NSTableView never claims it itself.
    AddSymbolItem(editMenu, STR_MENU_EDIT_SELECT_ALL, @"checklist", @selector(selectAll:), nil,
                  @"a", NSEventModifierFlagCommand, @"menu_edit_select_all");
}

+ (void)buildPlaybackMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenu *playbackMenu = Submenu(mainMenu, STR_MENU_PLAYBACK).submenu;
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PLAY, @"play.fill", @selector(playPause:), player, @" ", 0, kVibeMenuPlay);
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PREVIOUS, @"backward.end.fill", @selector(previous:), player, @"b", 0, kVibeMenuPreviousTrack);
    AddSymbolItem(playbackMenu, STR_TRANSPORT_NEXT, @"forward.end.fill", @selector(next:), player, @"n", 0, kVibeMenuNextTrack);
    // Bare keys are display and fallback only: TransportKeyMonitor handles
    // the presses.
    AddSymbolItem(playbackMenu, STR_MENU_PLAY_SELECTED, @"play.circle", @selector(playSelectedTrack:), player,
                  [NSString stringWithFormat:@"%c", NSCarriageReturnCharacter], 0, kVibeMenuPlaySelected);
    AddSeparator(playbackMenu);

    AddSymbolItem(playbackMenu, STR_MENU_SKIP_FORWARD, @"forward", @selector(skipForward:), player, @"a", 0, kVibeMenuSkipForward);
    AddItem(playbackMenu, STR_MENU_SKIP_FORWARD_MORE, @selector(skipForwardMore:), player, @"s", 0, kVibeMenuSkipForwardMore);
    AddItem(playbackMenu, STR_MENU_SKIP_FORWARD_MOST, @selector(skipForwardMost:), player, @"d", 0, kVibeMenuSkipForwardMost);
    AddSymbolItem(playbackMenu, STR_MENU_SKIP_BACK, @"backward", @selector(skipBack:), player, @"z", 0, kVibeMenuSkipBack);
    AddItem(playbackMenu, STR_MENU_SKIP_BACK_MORE, @selector(skipBackMore:), player, @"x", 0, kVibeMenuSkipBackMore);
    AddItem(playbackMenu, STR_MENU_SKIP_BACK_MOST, @selector(skipBackMost:), player, @"c", 0, kVibeMenuSkipBackMost);
    AddSeparator(playbackMenu);

    NSString *pitchRangeTitle = STR_MENU_PITCH_RANGE;
    NSMenuItem *pitchRangeItem = Submenu(playbackMenu, pitchRangeTitle);
    SetSymbolImage(pitchRangeItem, @"slider.vertical.3");
    NSMenu *pitchRangeMenu = pitchRangeItem.submenu;
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_8, @selector(setPitchRange:), player, @"", 0, kVibeMenuPitchRange8);
    AddItem(pitchRangeMenu, STR_MENU_PITCH_RANGE_16, @selector(setPitchRange:), player, @"", 0, kVibeMenuPitchRange16);
}

+ (void)buildFXMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Only TransportKeyMonitor can tell a tap (latch) from a hold (momentary).
    NSMenuItem *fxItem = Submenu(mainMenu, STR_MENU_FX);
    fxItem.identifier = @"menu_fx";
    NSMenu *fxMenu = fxItem.submenu;
    AddFXItem(fxMenu, STR_MENU_FX_LOW_KILL, @"dial.min", @selector(toggleLowKill:), player, @"q", kVibeMenuFXLowKill);
    AddFXItem(fxMenu, STR_MENU_FX_LOW_KILL_BOOST, @"dial.max.fill", @selector(toggleLowKillBoost:), player, @"w", kVibeMenuFXLowKillBoost);
    AddSeparator(fxMenu);
    AddFXItem(fxMenu, STR_MENU_FX_REVERB, @"water.waves", @selector(toggleReverbSend:), player, @"e", kVibeMenuFXReverb);
    AddFXItem(fxMenu, STR_MENU_FX_DELAY_8, @"repeat", @selector(toggleDelaySend:), player, @"r", kVibeMenuFXDelay);
    AddFXItem(fxMenu, STR_MENU_FX_DELAY_16, @"repeat.circle", @selector(toggleShortDelaySend:), player, @"t", kVibeMenuFXShortDelay);
    [self applyFXMenuVisibility:fxItem];
}

+ (void)buildViewMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenu *viewMenu = Submenu(mainMenu, STR_MENU_VIEW).submenu;
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PLAYLIST, @"list.dash", @selector(toggleSize:), player, [NSString stringWithFormat:@"%c", NSTabCharacter], 0, kVibeMenuShowPlaylist);
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PITCH_CONTROL, @"slider.vertical.3", @selector(togglePitchPanel:), player, @"p", 0, kVibeMenuShowPitch);
    AddSymbolItem(viewMenu, STR_MENU_VIEW_FILE_INFO, @"info.circle", @selector(toggleFileInfo:), player, @"", 0, kVibeMenuShowFileInfo);
    AddSeparator(viewMenu);

    NSMenu *themeMenu = Submenu(viewMenu, STR_MENU_VIEW_THEME).submenu;
    themeMenu.identifier = kVibeMenuThemeSubmenu;
    themeMenu.autoenablesItems = NO;
    themeMenu.delegate = player; // fills in the themes and the Edit tail

    // Body widths only; the height belongs to Show Playlist and the resize
    // handle.
    NSMenu *sizeMenu = Submenu(viewMenu, STR_MENU_VIEW_SIZE).submenu;
    AddItem(sizeMenu, STR_MENU_SIZE_SMALL, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall));
    AddItem(sizeMenu, STR_MENU_SIZE_DEFAULT, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetDefault));
    AddItem(sizeMenu, STR_MENU_SIZE_LARGE, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge));

    AddSeparator(viewMenu);
    AddSymbolItem(viewMenu, STR_MENU_VIEW_ALWAYS_ON_TOP, @"pin", @selector(toggleAlwaysOnTop:), player, @"", 0, kVibeMenuAlwaysOnTop);
    AddSymbolItem(viewMenu, STR_MENU_VIEW_LOCK_WINDOW_POSITION, @"lock", @selector(toggleWindowPositionLock:), player, @"", 0, kVibeMenuLockWindowPosition);
}

+ (void)buildConvertMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Always built, hidden in place by its settings effect.
    NSMenuItem *convertItem = Submenu(mainMenu, STR_MENU_CONVERT);
    convertItem.identifier = @"menu_convert";
    NSMenu *convertMenu = convertItem.submenu;
    [convertMenu addItem:[self convertToFLACItemWithTarget:player]];
    AddSeparator(convertMenu);
    AddSymbolItem(convertMenu, STR_MENU_CONVERT_DELETE_ORIGINAL, @"trash", @selector(toggleDeleteOriginalAfterConvert:), player, @"", 0, kVibeMenuConvertDeleteOriginal);
    [self applyConvertMenuVisibility:convertItem];
}

// The context menus' shared item hides through validation instead.
+ (void)applyConvertMenuVisibility {
    [self applyConvertMenuVisibility:TopLevelMenuItemWithIdentifier(@"menu_convert")];
}

+ (void)applyConvertMenuVisibility:(NSMenuItem *)convertItem {
    convertItem.hidden = !AppSettings.sharedInstance.convertEnabled;
}

+ (void)applyFXMenuVisibility {
    NSMenuItem *fxItem = TopLevelMenuItemWithIdentifier(@"menu_fx");
    if (!fxItem) {
        return;
    }
    [self applyFXMenuVisibility:fxItem];
}

// TRAP: hiding a submenu does not deactivate its key equivalents; AppKit still
// matches Q/W/E/R/T under a hidden menu_fx, so they are cleared with it.
+ (void)applyFXMenuVisibility:(NSMenuItem *)fxItem {
    BOOL enabled = AppSettings.sharedInstance.audioFXAllowed;
    for (NSMenuItem *item in fxItem.submenu.itemArray) {
        NSString *intendedKey = item.representedObject;
        if ([intendedKey isKindOfClass:NSString.class]) {
            item.keyEquivalent = enabled ? intendedKey : @"";
        }
    }
    fxItem.hidden = !enabled;
}

+ (void)buildOutputMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    NSMenu *outputMenu = Submenu(mainMenu, STR_MENU_OUTPUT).submenu;
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list
}

+ (void)buildHelpMenuIn:(NSMenu *)mainMenu appDelegate:(AppDelegate *)appDelegate {
    // Last, so it draws rightmost. Setting NSApp.helpMenu is what adds
    // AppKit's Search field in every language; found by title, it would only
    // be in English.
    NSMenuItem *helpItem = Submenu(mainMenu, STR_MENU_HELP);
    NSMenu *helpMenu = helpItem.submenu;
    AddSymbolItem(helpMenu, STR_MENU_HELP_SUPPORT, @"lifepreserver", @selector(showSupportPage:),
                  appDelegate, @"", 0, @"menu_help_support");
    NSApp.helpMenu = helpMenu;
}

@end
