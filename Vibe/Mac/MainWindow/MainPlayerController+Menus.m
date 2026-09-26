//
//  MainPlayerController+Menus.m
//  Vibe
//

#import "MainPlayerController+Menus.h"
#import "AppDelegate.h" // showThemeSettings:, the Edit tail's nil-targeted action
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Convert.h" // the two actions the Convert item swaps between
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Window.h" // contentWidthForSizeIdentifier:, for the Size checkmarks
#import "MenuValidationRules.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFX.h"
#import "MainWindow.h"
#import "PlaylistController.h"
#import "AudioTrack.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "VibeStrings.h"

@implementation MainPlayerController (Menus)

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    switch (VibeMenuValidationDomainForIdentifier(menuItem.identifier)) {
        case VibeMenuValidationDomainViewToggle:
            [self applyViewToggleStateToMenuItem:menuItem];
            if ([menuItem.identifier isEqualToString:kVibeMenuShowPitch]) {
                return AppSettings.sharedInstance.pitchControlAllowed;
            }
            return YES;
        case VibeMenuValidationDomainWindowSize:
            [self applyWindowSizeStateToMenuItem:menuItem];
            return YES;
        case VibeMenuValidationDomainFX:
            [self applyFXStateToMenuItem:menuItem];
            // TRAP: hiding a parent does not disable its descendants. The menu
            // builder removes their key equivalents; this also blocks direct
            // menu dispatch while the controls are off.
            return self.audioPlayer.fx != nil && AppSettings.sharedInstance.audioFXAllowed;
        case VibeMenuValidationDomainPitchRange:
            [self applyPitchRangeStateToMenuItem:menuItem];
            return YES;
        case VibeMenuValidationDomainTransport:
            return [self validateTransportMenuItem:menuItem];
        case VibeMenuValidationDomainFile:
            return [self validateFileMenuItem:menuItem];
        case VibeMenuValidationDomainEdit:
            return [self validateEditMenuItem:menuItem];
        case VibeMenuValidationDomainConvert:
            return [self validateConvertMenuItem:menuItem];
        case VibeMenuValidationDomainTheme:
            // menuNeedsUpdate: mints these and sets their state and enablement.
            return YES;
        case VibeMenuValidationDomainUnknown:
            break;
    }
    // Only items this controller is the target of reach here, so an unknown
    // one is a menu item that was added without a validation policy.
    LogWarn(@"Menu item %@ targets the player with no validation policy", menuItem.identifier);
    NSAssert(NO, @"unvalidated menu identifier %@ — add it to MenuValidationRules.h",
             menuItem.identifier);
    return NO;
}

#pragma mark - Presentation-only domains

// A preference or a window state, not an action, so each of these is a
// checkmark and nothing else: there is no condition under which the item
// should go unavailable.
- (void)applyViewToggleStateToMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    if ([menuItem.identifier isEqualToString:kVibeMenuShowPlaylist]) {
        menuItem.state = StateForBOOL(window.isPlaylistShown);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuShowPitch]) {
        menuItem.state = StateForBOOL(window.isPitchPanelShown);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuShowFileInfo]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.currentTheme.showFileInfo);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuAlwaysOnTop]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.alwaysOnTop);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuLockWindowPosition]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.windowPositionLocked);
    }
}

// Checkmark whichever preset the current body width already sits at, which
// after a drag-resize is none of them.
- (void)applyWindowSizeStateToMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    menuItem.state = StateForBOOL(window.contentWidth ==
            [MainPlayerController contentWidthForSizeIdentifier:menuItem.identifier]);
}

// One checkmark per effect. The controls outlive any single track, but become
// unavailable together when their stored setting hides the FX menu.
- (void)applyFXStateToMenuItem:(NSMenuItem *)menuItem {
    AudioFX *fx = self.audioPlayer.fx;
    if ([menuItem.identifier isEqualToString:kVibeMenuFXLowKill]) {
        menuItem.state = StateForBOOL(fx.lowKillEnabled);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuFXLowKillBoost]) {
        menuItem.state = StateForBOOL(fx.lowKillBoostActive);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuFXReverb]) {
        menuItem.state = StateForBOOL(fx.reverbSendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuFXDelay]) {
        menuItem.state = StateForBOOL(fx.delaySendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuFXShortDelay]) {
        menuItem.state = StateForBOOL(fx.shortDelaySendEnabled);
    }
}

- (void)applyPitchRangeStateToMenuItem:(NSMenuItem *)menuItem {
    NSInteger range = AppSettings.sharedInstance.pitchRange;
    if ([menuItem.identifier isEqualToString:kVibeMenuPitchRange8]) {
        menuItem.state = StateForBOOL(range == 8);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuPitchRange16]) {
        menuItem.state = StateForBOOL(range == 16);
    }
}

#pragma mark - Conditional domains

// A selection nobody can see is not a selection: with the playlist collapsed
// the arrow keys do not move one either (TransportKeyMonitor), so both commands
// that act on the selected row have nothing to act on. The key-window half is
// part of the same fact — a bare Return or Delete press in Settings or About
// falls through to these items' fallback key equivalents, and must not act on
// a playlist that is not even frontmost. One home, because both commands must
// agree; the play half used to skip the key-window check, which let Return in
// Settings start playback of a selection the user was not looking at.
- (BOOL)hasVisiblePlaylistSelection {
    MainWindow *window = (MainWindow *)self.window;
    return VibeMenuHasVisibleSelection(window.isKeyWindow, window.isPlaylistShown,
            self.playlistController.selectedRow);
}

- (BOOL)validateTransportMenuItem:(NSMenuItem *)menuItem {
    return VibeTransportMenuEnabled(menuItem.identifier, self.playlistController.hasNextTrack,
            self.playlistController.hasPreviousTrack, [self hasVisiblePlaylistSelection],
            self.playlistController.currentTrack != nil, self.audioPlayer.isStopped);
}

- (BOOL)validateFileMenuItem:(NSMenuItem *)menuItem {
    NSString *title = VibeFileMenuTitle(menuItem.identifier, self.playlistController.count,
            self.audioPlayer.isPlaying);
    if (title) menuItem.title = title;
    if ([menuItem.identifier isEqualToString:kVibeMenuPlay]) {
        menuItem.image = [NSImage imageWithSystemSymbolName:(self.audioPlayer.isPlaying ? @"pause.fill" : @"play.fill")
                                   accessibilityDescription:menuItem.title];
    }
    return VibeFileMenuEnabled(menuItem.identifier, self.playlistController.count,
            self.window.isKeyWindow, self.playlistController.currentTrack.url != nil);
}

- (BOOL)validateEditMenuItem:(NSMenuItem *)menuItem {
    // Stack titles and availability only: no filesystem reads during validation.
    NSUndoManager *manager = self.window.undoManager;
    if ([menuItem.identifier isEqualToString:kVibeMenuEditUndo]) menuItem.title = manager.undoMenuItemTitle;
    if ([menuItem.identifier isEqualToString:kVibeMenuEditRedo]) menuItem.title = manager.redoMenuItemTitle;
    return VibeEditMenuEnabled(menuItem.identifier, self.isConversionUndoRedoInFlight,
            manager.canUndo, manager.canRedo, [self hasVisiblePlaylistSelection],
            self.playlistController.currentTrack != nil, self.playlistController.currentTrack.url != nil);
}

- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem {
    // A preference, not an action, so never disabled.
    if ([menuItem.identifier isEqualToString:kVibeMenuConvertDeleteOriginal]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.deleteOriginalAfterConvert);
        return YES;
    }
    // The Convert menu's item and the window-body context menu's share this
    // identifier; the converter owns the idle enable-and-retitle rule. With
    // Convert switched off (Settings > Convert > Enabled) the whole feature is
    // hidden — the menu bar's Convert menu through applyConvertMenuVisibility,
    // and this shared item here, which is how the context menus follow the
    // setting live.
    menuItem.hidden = !AppSettings.sharedInstance.convertEnabled;
    if (menuItem.hidden) {
        return NO;
    }
    // One item, re-aimed: while a conversion runs it is the enabled Cancel
    // Conversion, the sweep's only affordance. Swapped here rather than in the
    // converter, which cannot name this controller's selectors; a click landing
    // after the conversion settles reaches a cancel that is a no-op by then.
    BOOL converting = self.fileConverter.isConverting;
    menuItem.action = VibeConvertMenuAction(converting);
    if (converting) {
        menuItem.title = VibeConvertMenuTitle(converting);
        return YES;
    }
    return [self.fileConverter validateConvertMenuItem:menuItem
                                              forTrack:self.playlistController.currentTrack];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (![menu.identifier isEqualToString:kVibeMenuThemeSubmenu]) {
        return;
    }
    // Rebuilt whole on every open: themes are added, renamed and removed at
    // runtime, and a full rebuild is simpler than teaching incremental item
    // arithmetic about the static Edit tail.
    [menu removeAllItems];
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *active = settings.activeThemeIdentifier;
    for (NSString *identifier in settings.orderedThemeIdentifiers) {
        NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:[settings displayNameForThemeIdentifier:identifier] ?: identifier
                       action:@selector(selectTheme:)
                keyEquivalent:@""];
        // The identifier travels on the item — a display name can't
        // round-trip into the store — and gives click_menu a stable id.
        item.representedObject = identifier;
        item.identifier = VibeThemeMenuIdentifier(identifier);
        item.state = StateForBOOL([identifier isEqualToString:active]);
        item.target = self;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    // Nil-targeted: the app delegate answers showThemeSettings:, the same
    // ownership as Settings… itself.
    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:STR_MENU_VIEW_EDIT_THEMES
                                                  action:@selector(showThemeSettings:)
                                           keyEquivalent:@""];
    edit.identifier = kVibeMenuEditThemes;
    [menu addItem:edit];
}

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate:, a full
// submenu rebuild, on every keyDown. OutputDevicesMenuController follows the
// same pattern. The theme items carry no key equivalents.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (IBAction)selectTheme:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        NSString *identifier = ((NSMenuItem *)sender).representedObject;
        if (identifier) {
            [AppSettings.sharedInstance applyThemeWithIdentifier:identifier];
            [self applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
        }
    }
}

- (void)refreshWaveformTheme {
    [self.waveformView refreshThemeColors];
}

@end
