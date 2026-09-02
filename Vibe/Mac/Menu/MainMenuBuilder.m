//
//  MainMenuBuilder.m
//  Vibe
//

#import "MainMenuBuilder.h"
#import "AppDelegate.h"
#import "AppSettings.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Convert.h"
#import "MainPlayerController+Transport.h"
#import "MenuValidationRules.h"
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

static NSMenuItem *AddFXItem(NSMenu *parent, NSString *title, NSString *symbolName, SEL action,
                             id target, NSString *key, NSString *identifier) {
    NSMenuItem *item = AddSymbolItem(parent, title, symbolName, action, target, key, 0, identifier);
    // Keep the intended shortcut while the live setting clears keyEquivalent.
    // AppKit still matches descendants of a hidden top-level menu.
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
                      target, @"", 0, @"menu_edit_copy_name");
}

+ (NSMenuItem *)copyFileItemWithTarget:(id)target {
    return SymbolItem(STR_MENU_EDIT_COPY_FILE, @"doc.on.doc", @selector(copyFile:),
                      target, @"", 0, @"menu_edit_copy_file");
}

+ (NSMenuItem *)convertToFLACItemWithTarget:(id)target {
    return SymbolItem(STR_MENU_CONVERT_TO_FLAC, @"arrow.triangle.2.circlepath",
                      @selector(convertCurrentTrackToFLAC:), target, @"", 0, @"menu_convert_to_flac");
}
// One method per top-level menu, in the order they appear in the bar, so a
// change to the View menu is a change to one method rather than a scroll
// through eight. Each helper owns its whole submenu tree; the order of the
// calls below IS the left-to-right order of the menu bar.
+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)player
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    // Never drawn: the root menu's title isn't rendered anywhere.
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Main Menu")];

    [self buildAppMenuIn:mainMenu appDelegate:appDelegate];
    [self buildFileMenuIn:mainMenu openRecentMenuController:openRecentMenuController];
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
    // Vibe (application menu). macOS draws CFBundleName in bold for the first
    // menu regardless of the title set here.
    NSMenu *appMenu = Submenu(mainMenu, appName).submenu;
    AddItem(appMenu, [NSString stringWithFormat:STR_MENU_APP_ABOUT, appName],
            @selector(showAboutWindow:), appDelegate, @"", 0, nil);
    AddSeparator(appMenu);

    AddSymbolItem(appMenu, STR_MENU_APP_SETTINGS, @"gearshape",
                  @selector(showSettingsWindow:), appDelegate, @",", NSEventModifierFlagCommand, @"menu_settings");
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
}

+ (void)buildFileMenuIn:(NSMenu *)mainMenu openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController {
    // File
    NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
    AddItem(fileMenu, STR_MENU_FILE_OPEN, @selector(openDocument:), nil, @"o", NSEventModifierFlagCommand, nil);
    NSMenuItem *openRecentItem = Submenu(fileMenu, STR_MENU_FILE_OPEN_RECENT);
    openRecentItem.submenu.delegate = openRecentMenuController; // populated from NSDocumentController on open
    AddSeparator(fileMenu);
    // Nil-targeted so ⌘W follows the key window: the main window's chain
    // reaches the player's closeFile:; Settings and About intercept it and
    // close themselves instead.
    AddSymbolItem(fileMenu, STR_MENU_FILE_CLOSE, @"xmark", @selector(closeFile:), nil, @"w", NSEventModifierFlagCommand, @"menu_close");
}

+ (void)buildEditMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Edit: undo, redo, the two copy items and Remove from Playlist below —
    // the app has no text selection, so none of the standard editing items.
    // Validation retitles undo and redo from NSUndoManager.
    NSMenuItem *editItem = Submenu(mainMenu, STR_MENU_EDIT);
    NSMenu *editMenu = editItem.submenu;
    // The delegate reference is weak, so the Edit item itself retains its
    // cleaner: ownership rides the menu it works for, per the header's rule,
    // and the builder stays a stateless one-shot.
    VibeEditMenuCleaner *editMenuCleaner = [VibeEditMenuCleaner new];
    editItem.representedObject = editMenuCleaner;
    editMenu.delegate = editMenuCleaner;
    AddSymbolItem(editMenu, STR_MENU_EDIT_UNDO, @"arrow.uturn.backward", @selector(undo:), player, @"z", NSEventModifierFlagCommand, @"menu_edit_undo");
    // ⇧⌘Z — capital "Z", same contract as Copy Name's "C" below.
    AddSymbolItem(editMenu, STR_MENU_EDIT_REDO, @"arrow.uturn.forward", @selector(redo:), player, @"Z", NSEventModifierFlagCommand, @"menu_edit_redo");
    // The cleaner keeps only menu_edit_*-identified items, the separator
    // included.
    AddSeparator(editMenu).identifier = @"menu_edit_separator";

    // Copy Name copies the header's "Artist - Title" line as text; Copy File
    // puts the current track's file URL on the general pasteboard, so a
    // Finder paste duplicates the file. The items are the vended ones the
    // window-body context menu also uses; only the key equivalents are the
    // menu bar's own. Copy Name's ⇧⌘ rides in the capital "C", per the
    // NSMenuItem contract — a lowercase key with Shift in the mask draws
    // right but never matches a real key press (charactersIgnoringModifiers
    // arrives uppercase).
    NSMenuItem *copyNameItem = [self copyNameItemWithTarget:player];
    copyNameItem.keyEquivalent = @"C";
    copyNameItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [editMenu addItem:copyNameItem];
    NSMenuItem *copyFileItem = [self copyFileItemWithTarget:player];
    copyFileItem.keyEquivalent = @"c";
    copyFileItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [editMenu addItem:copyFileItem];

    AddSeparator(editMenu).identifier = @"menu_edit_separator_remove";
    // minus.circle, not trash: this edits the in-memory playlist and leaves the
    // file on disk. The equivalent is NSBackspaceCharacter because that is what
    // AppKit draws as ⌫ — a real Backspace press delivers NSDeleteCharacter, so
    // like the other bare keys this is display and fallback only and
    // TransportKeyMonitor does the actual handling, for Forward Delete too.
    AddSymbolItem(editMenu, STR_MENU_EDIT_REMOVE_FROM_PLAYLIST, @"minus.circle",
                  @selector(removeSelectedPlaylistTracks:), player,
                  [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter], 0,
                  @"menu_edit_remove_from_playlist");

    AddSeparator(editMenu).identifier = @"menu_edit_separator_select";
    // The one Edit item with NO explicit target: ⌘A has to reach whichever
    // list has keyboard focus — the playlist, or the granted-folder list in
    // Settings > Permissions — so it rides the responder chain instead.
    // Without an item carrying the key equivalent nothing sends selectAll: at
    // all, since AppKit dispatches ⌘A through the menu bar and NSTableView
    // never claims it itself.
    AddSymbolItem(editMenu, STR_MENU_EDIT_SELECT_ALL, @"checklist", @selector(selectAll:), nil,
                  @"a", NSEventModifierFlagCommand, @"menu_edit_select_all");
}

+ (void)buildPlaybackMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Playback
    NSMenu *playbackMenu = Submenu(mainMenu, STR_MENU_PLAYBACK).submenu;
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PLAY, @"play.fill", @selector(playPause:), player, @" ", 0, @"menu_play");
    AddSymbolItem(playbackMenu, STR_TRANSPORT_PREVIOUS, @"backward.end.fill", @selector(previous:), player, @"b", 0, @"menu_previous_track");
    AddSymbolItem(playbackMenu, STR_TRANSPORT_NEXT, @"forward.end.fill", @selector(next:), player, @"n", 0, @"menu_next_track");
    // Bare Return, the keyboard twin of a double-click on the row. It is
    // enabled only while the playlist is showing and a row is selected; see
    // the Menus category. TransportKeyMonitor handles the press itself, like
    // every other bare key here.
    AddSymbolItem(playbackMenu, STR_MENU_PLAY_SELECTED, @"play.circle", @selector(playSelectedTrack:), player,
                  [NSString stringWithFormat:@"%c", NSCarriageReturnCharacter], 0, @"menu_play_selected");
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
}

+ (void)buildFXMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // FX: the DJ performance effects, one item per bare key — Q, W, E, R and
    // T, at mask 0. As with the skip keys, the equivalents here are for
    // display and as the fallback path. TransportKeyMonitor actually handles
    // the presses, and it alone can tell a tap, which latches like these
    // toggles, from a hold, which is momentary. While exposed, they stay
    // enabled because they are deck controls that persist across tracks and
    // apply to whatever is playing or starts to play. Validation shows each
    // one's state as a checkmark. The graph is a launch-time choice; when one
    // exists, the stored setting can still hide these controls immediately.
    if (player.audioPlayer.fx) {
        NSMenuItem *fxItem = Submenu(mainMenu, STR_MENU_FX);
        fxItem.identifier = @"menu_fx";
        NSMenu *fxMenu = fxItem.submenu;
        AddFXItem(fxMenu, STR_MENU_FX_LOW_KILL, @"dial.min", @selector(toggleLowKill:), player, @"q", @"menu_fx_low_kill");
        AddFXItem(fxMenu, STR_MENU_FX_LOW_KILL_BOOST, @"dial.max.fill", @selector(toggleLowKillBoost:), player, @"w", @"menu_fx_low_kill_boost");
        AddSeparator(fxMenu);
        AddFXItem(fxMenu, STR_MENU_FX_REVERB, @"water.waves", @selector(toggleReverbSend:), player, @"e", @"menu_fx_reverb");
        AddFXItem(fxMenu, STR_MENU_FX_DELAY_8, @"repeat", @selector(toggleDelaySend:), player, @"r", @"menu_fx_delay");
        AddFXItem(fxMenu, STR_MENU_FX_DELAY_16, @"repeat.circle", @selector(toggleShortDelaySend:), player, @"t", @"menu_fx_short_delay");
        [self applyFXMenuVisibility:fxItem];
    }
}

+ (void)buildViewMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // View
    NSMenu *viewMenu = Submenu(mainMenu, STR_MENU_VIEW).submenu;
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PLAYLIST, @"list.dash", @selector(toggleSize:), player, [NSString stringWithFormat:@"%c", NSTabCharacter], 0, @"menu_show_playlist");
    AddSymbolItem(viewMenu, STR_MENU_VIEW_PITCH_CONTROL, @"slider.vertical.3", @selector(togglePitchPanel:), player, @"p", 0, @"menu_show_pitch");
    AddSymbolItem(viewMenu, STR_MENU_VIEW_FILE_INFO, @"info.circle", @selector(toggleFileInfo:), player, @"", 0, @"menu_show_file_info");
    AddSeparator(viewMenu);

    NSMenu *themeMenu = Submenu(viewMenu, STR_MENU_VIEW_THEME).submenu;
    themeMenu.identifier = @"view_theme";
    themeMenu.autoenablesItems = NO;
    themeMenu.delegate = player; // fills in the themes and the Edit tail

    // The width presets: the drag minimum, the design width, and 1.75 times
    // the design width; see setWindowSize:. The height is deliberately
    // untouched, since it belongs to Show Playlist and the resize handle.
    NSMenu *sizeMenu = Submenu(viewMenu, STR_MENU_VIEW_SIZE).submenu;
    AddItem(sizeMenu, STR_MENU_SIZE_SMALL, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall));
    AddItem(sizeMenu, STR_MENU_SIZE_DEFAULT, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetDefault));
    AddItem(sizeMenu, STR_MENU_SIZE_LARGE, @selector(setWindowSize:), player, @"", 0,
            VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge));

    NSMenu *appearanceMenu = Submenu(viewMenu, STR_MENU_VIEW_APPEARANCE).submenu;
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_SYSTEM, @selector(setAppearance:), player, @"", 0, @"view_appearance_system_default");
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_LIGHT, @selector(setAppearance:), player, @"", 0, @"view_appearance_light");
    AddItem(appearanceMenu, STR_MENU_APPEARANCE_DARK, @selector(setAppearance:), player, @"", 0, @"view_appearance_dark");

    AddSeparator(viewMenu);
    AddSymbolItem(viewMenu, STR_MENU_VIEW_ALWAYS_ON_TOP, @"pin", @selector(toggleAlwaysOnTop:), player, @"", 0, @"menu_always_on_top");
}

+ (void)buildConvertMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Convert is always built and hidden in place by its settings effect.
    NSMenuItem *convertItem = Submenu(mainMenu, STR_MENU_CONVERT);
    convertItem.identifier = @"menu_convert";
    NSMenu *convertMenu = convertItem.submenu;
    // Enabled only for an uncompressed current track with no FLAC beside it
    // yet; validation retitles it with the reason otherwise.
    [convertMenu addItem:[self convertToFLACItemWithTarget:player]];
    AddSeparator(convertMenu);
    // A checkmarked preference rather than an action, so it is always enabled.
    AddSymbolItem(convertMenu, STR_MENU_CONVERT_DELETE_ORIGINAL, @"trash", @selector(toggleDeleteOriginalAfterConvert:), player, @"", 0, @"menu_convert_delete_original");
    [self applyConvertMenuVisibility:convertItem];
}

// The ConvertMenu settings effect calls this after a write, and the build
// above seeds the initial state through the one-item variant. The context
// menus' shared Convert to FLAC item hides through validation instead.
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

+ (void)applyFXMenuVisibility:(NSMenuItem *)fxItem {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    for (NSMenuItem *item in fxItem.submenu.itemArray) {
        NSString *intendedKey = item.representedObject;
        if ([intendedKey isKindOfClass:NSString.class]) {
            item.keyEquivalent = enabled ? intendedKey : @"";
        }
    }
    fxItem.hidden = !enabled;
}

+ (void)buildOutputMenuIn:(NSMenu *)mainMenu player:(MainPlayerController *)player {
    // Output
    NSMenu *outputMenu = Submenu(mainMenu, STR_MENU_OUTPUT).submenu;
    outputMenu.autoenablesItems = NO;
    outputMenu.delegate = player.devicesMenuController; // builds the device list
}

+ (void)buildHelpMenuIn:(NSMenu *)mainMenu appDelegate:(AppDelegate *)appDelegate {
    // Help, last so it draws rightmost, as macOS expects. Registering it as
    // NSApp.helpMenu is what puts AppKit's own Search field at the top —
    // it searches the menu bar, and the app ships no help book, so Get
    // Support is the only item of ours here. Naming the menu explicitly beats
    // letting AppKit find it by title, which it does only in English.
    NSMenuItem *helpItem = Submenu(mainMenu, STR_MENU_HELP);
    NSMenu *helpMenu = helpItem.submenu;
    AddSymbolItem(helpMenu, STR_MENU_HELP_SUPPORT, @"lifepreserver", @selector(showSupportPage:),
                  appDelegate, @"", 0, @"menu_help_support");
    NSApp.helpMenu = helpMenu;
}

@end
