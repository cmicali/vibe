//
//  MainPlayerController+Menus.m
//  Vibe
//

#import "MainPlayerController+Menus.h"
#import "AppDelegate.h" // showThemeSettings:, the Edit tail's nil-targeted action
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Window.h" // contentWidthForSizeIdentifier:, for the Size checkmarks
#import "MenuValidationRules.h"
#import "AppSettings.h"
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
            return YES;
        case VibeMenuValidationDomainWindowSize:
            [self applyWindowSizeStateToMenuItem:menuItem];
            return YES;
        case VibeMenuValidationDomainAppearance:
            [self applyAppearanceStateToMenuItem:menuItem];
            // A single-mode theme pins the window dark and ignores this
            // setting; disable it there so the checkmark can't assert a state
            // the window contradicts.
            return !AppSettings.sharedInstance.currentTheme.isSingleMode;
        case VibeMenuValidationDomainFX:
            [self applyFXStateToMenuItem:menuItem];
            // TRAP: hiding a parent does not disable its descendants. The menu
            // builder removes their key equivalents; this also blocks direct
            // menu dispatch while the controls are off.
            return self.audioPlayer.fx != nil && AppSettings.sharedInstance.audioFXEnabled;
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
    if ([menuItem.identifier isEqualToString:@"menu_show_playlist"]) {
        menuItem.state = StateForBOOL(window.isPlaylistShown);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_show_pitch"]) {
        menuItem.state = StateForBOOL(window.isPitchPanelShown);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_show_file_info"]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.currentTheme.showFileInfo);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_always_on_top"]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.alwaysOnTop);
    }
}

// Checkmark whichever preset the current body width already sits at, which
// after a drag-resize is none of them.
- (void)applyWindowSizeStateToMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    menuItem.state = StateForBOOL(window.contentWidth ==
            [MainPlayerController contentWidthForSizeIdentifier:menuItem.identifier]);
}

- (void)applyAppearanceStateToMenuItem:(NSMenuItem *)menuItem {
    NSString *style = AppSettings.sharedInstance.windowAppearanceStyle;
    if ([menuItem.identifier isEqualToString:@"view_appearance_system_default"]) {
        menuItem.state = StateForString(style, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_light"]) {
        menuItem.state = StateForString(style, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_dark"]) {
        menuItem.state = StateForString(style, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK);
    }
}

// One checkmark per effect. The controls outlive any single track, but become
// unavailable together when their stored setting hides the FX menu.
- (void)applyFXStateToMenuItem:(NSMenuItem *)menuItem {
    AudioFX *fx = self.audioPlayer.fx;
    if ([menuItem.identifier isEqualToString:@"menu_fx_low_kill"]) {
        menuItem.state = StateForBOOL(fx.lowKillEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_low_kill_boost"]) {
        menuItem.state = StateForBOOL(fx.lowKillBoostActive);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_reverb"]) {
        menuItem.state = StateForBOOL(fx.reverbSendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_delay"]) {
        menuItem.state = StateForBOOL(fx.delaySendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_short_delay"]) {
        menuItem.state = StateForBOOL(fx.shortDelaySendEnabled);
    }
}

- (void)applyPitchRangeStateToMenuItem:(NSMenuItem *)menuItem {
    NSInteger range = AppSettings.sharedInstance.pitchRange;
    if ([menuItem.identifier isEqualToString:@"pitch_range_8"]) {
        menuItem.state = StateForBOOL(range == 8);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_16"]) {
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
    return window.isKeyWindow && window.isPlaylistShown
            && self.playlistController.selectedRow >= 0;
}

- (BOOL)validateTransportMenuItem:(NSMenuItem *)menuItem {
    // Only when there really is a track after the current one. At the end of
    // the playlist, next: is a no-op.
    if ([menuItem.identifier isEqualToString:@"menu_next_track"]) {
        return self.playlistController.hasNextTrack;
    }
    if ([menuItem.identifier isEqualToString:@"menu_previous_track"]) {
        return self.playlistController.hasPreviousTrack;
    }
    if ([menuItem.identifier isEqualToString:@"menu_play_selected"]) {
        return [self hasVisiblePlaylistSelection];
    }
    // The skips need both a loaded track and a player that is not stopped:
    // after the playlist ends there is no node left to seek. See
    // skipByFileSeconds:.
    return self.playlistController.currentTrack != nil && !self.audioPlayer.isStopped;
}

- (BOOL)validateFileMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"menu_play"]) {
        // The action is playPause:, so mirror the toggle in the title and
        // icon, as standard macOS players do. During Loading, isPlaying
        // follows whether the pending open will start or park.
        BOOL playing = self.audioPlayer.isPlaying;
        menuItem.title = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
        menuItem.image = [NSImage imageWithSystemSymbolName:(playing ? @"pause.fill" : @"play.fill")
                                   accessibilityDescription:menuItem.title];
        return self.playlistController.count > 0;
    }
    if ([menuItem.identifier isEqualToString:@"menu_close"]) {
        menuItem.title = self.playlistController.count > 1 ? STR_MENU_FILE_CLOSE_ALL : STR_MENU_FILE_CLOSE;
        // Nil-targeted, so the key window's closeFile: target owns both the
        // action and this shared item's title. Settings and About restore the
        // singular title in their own validators.
        return self.playlistController.count > 0;
    }
    return self.playlistController.currentTrack.url != nil;   // show_in_finder
}

- (BOOL)validateEditMenuItem:(NSMenuItem *)menuItem {
    // NSUndoManager's own state and titles, never a stat; an emptied Trash
    // surfaces only when the restore runs.
    if ([menuItem.identifier isEqualToString:@"menu_edit_undo"]) {
        menuItem.title = self.window.undoManager.undoMenuItemTitle;
        return !self.isConversionUndoRedoInFlight && self.window.undoManager.canUndo;
    }
    if ([menuItem.identifier isEqualToString:@"menu_edit_redo"]) {
        menuItem.title = self.window.undoManager.redoMenuItemTitle;
        return !self.isConversionUndoRedoInFlight && self.window.undoManager.canRedo;
    }
    // The one structural edit: it acts on the SELECTED row, so it shares Play
    // Selected Track's whole gate — key window included.
    if ([menuItem.identifier isEqualToString:@"menu_edit_remove_from_playlist"]) {
        return [self hasVisiblePlaylistSelection];
    }
    // The Copy items act on the current track, like Show in Finder.
    if ([menuItem.identifier isEqualToString:@"menu_edit_copy_file"]) {
        return self.playlistController.currentTrack.url != nil;
    }
    return self.playlistController.currentTrack != nil;   // menu_edit_copy_name
}

- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem {
    // A preference, not an action, so never disabled.
    if ([menuItem.identifier isEqualToString:@"menu_convert_delete_original"]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.deleteOriginalAfterConvert);
        return YES;
    }
    // The Convert menu's item and the window-body context menu's share this
    // identifier; the converter owns the enable-and-retitle rule. With Convert
    // switched off (Settings > Convert > Enabled) the whole feature is hidden —
    // the menu bar's Convert menu through applyConvertMenuVisibility, and this
    // shared item here, which is how the context menus follow the setting live.
    menuItem.hidden = !AppSettings.sharedInstance.convertEnabled;
    if (menuItem.hidden) {
        return NO;
    }
    return [self.fileConverter validateConvertMenuItem:menuItem
                                              forTrack:self.playlistController.currentTrack];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (![menu.identifier isEqualToString:@"view_theme"]) {
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
    edit.identifier = @"menu_edit_themes";
    [menu addItem:edit];
}

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate:, a full
// submenu rebuild, on every keyDown. OutputDevicesMenuController follows the
// same pattern. The style items carry no key equivalents.
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

- (NSArray<NSString *> *)availableWaveformStyleIdentifiers {
    return self.waveformView.availableWaveformStyles;
}

- (NSString *)displayNameForWaveformStyle:(NSString *)identifier {
    return [self.waveformView displayNameForStyle:identifier];
}

- (void)refreshWaveformTheme {
    [self.waveformView refreshThemeColors];
}

@end
