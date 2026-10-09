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
#import "MainMenuBuilder.h"
#import "MenuValidationRules.h"
#import "SettingsRules.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFX.h"
#import "MainWindow.h"
#import "PlaylistController.h"
#import "AudioTrack.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "VibeStrings.h"

// Validation runs on every menu open and every bound keypress, a held skip
// key's at key-repeat rate, so each symbol is built once. Its description is
// the title it first draws beside, which the symbol alone decides.
static NSImage *MenuSymbolImage(NSString *symbol, NSString *description) {
    static NSMutableDictionary<NSString *, NSImage *> *images;
    if (!images) {
        images = [NSMutableDictionary dictionary];
    }
    NSImage *image = images[symbol];
    if (!image) {
        image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:description];
        images[symbol] = image;
    }
    return image;
}

@implementation MainPlayerController (Menus)

- (BOOL)performMenuItem:(NSMenuItem *)item {
    // TRAP: AppKit gives a submenu parent submenuAction: even when it was
    // built with action:NULL, and sending that to a responder that does not
    // implement it aborts the app.
    if (item.hasSubmenu) {
        return NO;
    }
    [item.menu update]; // the validation pass opening the menu would run
    return item.isEnabled && !item.isHiddenOrHasHiddenAncestor && item.action
            && [NSApp sendAction:item.action to:item.target from:item];
}

- (BOOL)performMenuCommandWithIdentifier:(NSString *)identifier {
    NSMenuItem *item = [MainMenuBuilder mainMenuItemWithIdentifier:identifier];
    if (!item) {
        return NO;
    }
    [self performMenuItem:item];
    return !item.isHiddenOrHasHiddenAncestor; // after validation, which hides Convert's
}

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
            // TRAP: hiding the FX menu does not disable its items. The builder
            // clears their key equivalents; this blocks direct dispatch.
            return self.audioPlayer.fx != nil && AppSettings.sharedInstance.audioFXAllowed;
        case VibeMenuValidationDomainPitchRange:
            [self applyPitchRangeStateToMenuItem:menuItem];
            return YES;
        case VibeMenuValidationDomainPlayOrder:
            [self applyPlayOrderStateToMenuItem:menuItem];
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
    // Only this controller's items reach here: one was added with no policy.
    LogWarn(@"Menu item %@ targets the player with no validation policy", menuItem.identifier);
    NSAssert(NO, @"unvalidated menu identifier %@ — add it to MenuValidationRules.h",
             menuItem.identifier);
    return NO;
}

#pragma mark - Presentation-only domains

- (void)applyViewToggleStateToMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    if ([menuItem.identifier isEqualToString:kVibeMenuShowPlaylist]) {
        menuItem.state = StateForBOOL(window.isPlaylistShown);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuShowPitch]) {
        menuItem.state = StateForBOOL(window.isPitchPanelShown);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuAlwaysOnTop]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.alwaysOnTop);
    }
    else if ([menuItem.identifier isEqualToString:kVibeMenuLockWindowPosition]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.windowPositionLocked);
    }
}

// After a drag-resize, none of them.
- (void)applyWindowSizeStateToMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    menuItem.state = StateForBOOL(window.contentWidth ==
            [MainPlayerController contentWidthForSizeIdentifier:menuItem.identifier]);
}

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

- (void)applyPlayOrderStateToMenuItem:(NSMenuItem *)menuItem {
    AppSettings *settings = AppSettings.sharedInstance;
    if ([menuItem.identifier isEqualToString:kVibeMenuShuffle]) {
        menuItem.state = StateForBOOL(settings.shuffleEnabled);
        return;
    }
    VibeRepeatMode mode = settings.repeatMode;
    menuItem.title = VibeRepeatModeTitle(mode);
    menuItem.state = StateForBOOL(mode != VibeRepeatModeOff);
    menuItem.image = MenuSymbolImage(VibeRepeatModeSymbolName(mode), menuItem.title);
}

#pragma mark - Conditional domains

// Play Selected and Remove share this so they agree. Collapsed, the arrow
// keys move no selection; and a bare Return or Delete in Settings or About
// falls through to these items' key equivalents, and must not act on a
// playlist that is not frontmost.
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
        menuItem.image = MenuSymbolImage(self.audioPlayer.isPlaying ? @"pause.fill" : @"play.fill", menuItem.title);
    }
    return VibeFileMenuEnabled(menuItem.identifier, self.playlistController.count,
            self.window.isKeyWindow, self.playlistController.currentTrack.url != nil);
}

- (BOOL)validateEditMenuItem:(NSMenuItem *)menuItem {
    // The stack alone: no filesystem reads during validation.
    NSUndoManager *manager = self.window.undoManager;
    if ([menuItem.identifier isEqualToString:kVibeMenuEditUndo]) menuItem.title = manager.undoMenuItemTitle;
    if ([menuItem.identifier isEqualToString:kVibeMenuEditRedo]) menuItem.title = manager.redoMenuItemTitle;
    return VibeEditMenuEnabled(menuItem.identifier, self.isConversionUndoRedoInFlight,
            manager.canUndo, manager.canRedo, [self hasVisiblePlaylistSelection],
            self.playlistController.currentTrack != nil, self.playlistController.currentTrack.url != nil,
            [self focusedTextView] != nil);
}

- (nullable NSTextView *)focusedTextView {
    NSResponder *responder = NSApp.keyWindow.firstResponder;
    return [responder isKindOfClass:NSTextView.class] ? (NSTextView *)responder : nil;
}

- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem {
    // A preference, never disabled.
    if ([menuItem.identifier isEqualToString:kVibeMenuConvertDeleteOriginal]) {
        menuItem.state = StateForBOOL(AppSettings.sharedInstance.deleteOriginalAfterConvert);
        return YES;
    }
    // Shared with the window-body context menu. Hiding it here is how the
    // context menus follow the Convert setting live.
    menuItem.hidden = !AppSettings.sharedInstance.convertEnabled;
    if (menuItem.hidden) {
        return NO;
    }
    // While converting, the same item is the enabled Cancel Conversion, the
    // sweep's only affordance. A click after it settles cancels nothing.
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
    // Rebuilt whole on every open: themes change at runtime.
    [menu removeAllItems];
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *active = settings.activeThemeIdentifier;
    for (NSString *identifier in settings.orderedThemeIdentifiers) {
        NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:[settings displayNameForThemeIdentifier:identifier] ?: identifier
                       action:@selector(selectTheme:)
                keyEquivalent:@""];
        // A display name cannot round-trip into the store.
        item.representedObject = identifier;
        item.identifier = VibeThemeMenuIdentifier(identifier);
        item.state = StateForBOOL([identifier isEqualToString:active]);
        item.target = self;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    // Nil-targeted: the app delegate owns it, as it does Settings….
    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:STR_MENU_VIEW_EDIT_THEMES
                                                  action:@selector(showThemeSettings:)
                                           keyEquivalent:@""];
    edit.identifier = kVibeMenuEditThemes;
    [menu addItem:edit];
}

// Without this, AppKit's key-equivalent scan rebuilds the submenu through
// menuNeedsUpdate: on every keyDown. The theme items have no equivalents.
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
