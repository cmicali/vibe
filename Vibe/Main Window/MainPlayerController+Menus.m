//
//  MainPlayerController+Menus.m
//  Vibe
//

#import "MainPlayerController+Menus.h"
#import "AudioFX.h"
#import "MainWindow.h"
#import "PlaylistController.h"
#import "AudioTrack.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "VibeStrings.h"

// The class extension in MainPlayerController.m synthesizes waveformView, and
// it is re-declared readonly here, the same pattern as
// MainPlayerController+Debug.h, so that the waveform-style submenu code can
// read it. contentWidthForSizeIdentifier: is defined next to setWindowSize:,
// because the Size checkmarks must resolve the same identifier-to-width
// mapping the action does.
@interface MainPlayerController (MenuOutlets)
@property (weak, readonly) AudioWaveformView *waveformView;
+ (CGFloat)contentWidthForSizeIdentifier:(NSString *)identifier;
@end

@implementation MainPlayerController (Menus)

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    if ([menuItem.identifier isEqualToString:@"menu_show_playlist"]) {
        menuItem.state = StateForBOOL(window.isPlaylistShown);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_show_pitch"]) {
        menuItem.state = StateForBOOL(window.isPitchPanelShown);
    }
    // Size: checkmark whichever preset the current body width already sits at,
    // which after a drag-resize is none of them.
    else if ([menuItem.identifier hasPrefix:@"view_size_"]) {
        menuItem.state = StateForBOOL(window.contentWidth ==
                [MainPlayerController contentWidthForSizeIdentifier:menuItem.identifier]);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_system_default"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_light"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_dark"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_next_track"]) {
        // Only when there really is a track after the current one. At the end
        // of the playlist, next: is a no-op.
        return self.playlistController.hasNextTrack;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_previous_track"]) {
        return self.playlistController.hasPreviousTrack;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_skip_forward"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_forward_more"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_forward_most"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back_more"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back_most"]) {
        // This needs both a loaded track and a player that is not stopped:
        // after the playlist ends there is no node left to seek. See
        // skipByFileSeconds:.
        return self.playlistController.currentTrack != nil && !self.audioPlayer.isStopped;
    }
    // FX: one checkmark per effect. They are never disabled, because the
    // effects are deck controls that outlive any single track; see the FX menu
    // in MainMenuBuilder.
    else if ([menuItem.identifier isEqualToString:@"menu_fx_low_kill"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.fx.lowKillEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_low_kill_boost"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.fx.lowKillBoostActive);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_reverb"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.fx.reverbSendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_delay"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.fx.delaySendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_fx_short_delay"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.fx.shortDelaySendEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_8"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 8);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_16"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 16);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_play"]) {
        // The action is playPause:, so mirror the toggle in the title and
        // icon, as standard macOS players do. isPlaying covers Loading: a play
        // is committed, so the available action is Pause.
        BOOL playing = self.audioPlayer.isPlaying;
        menuItem.title = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
        menuItem.image = [NSImage imageWithSystemSymbolName:(playing ? @"pause.fill" : @"play.fill")
                                   accessibilityDescription:menuItem.title];
        return self.playlistController.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_close"]) {
        menuItem.title = self.playlistController.count > 1 ? STR_MENU_FILE_CLOSE_ALL : STR_MENU_FILE_CLOSE;
        // Nil-targeted, so this validates only when the player's responder
        // chain owns ⌘W — the Settings and About windows intercept closeFile:
        // themselves while key. No key-window check needed here.
        return self.playlistController.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"show_in_finder"]) {
        return self.playlistController.currentTrack.url != nil;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_convert_to_flac"]) {
        // The Convert menu's item and the window-body context menu's share
        // this identifier; the converter owns the enable-and-retitle rule.
        return [self.fileConverter validateConvertMenuItem:menuItem
                                                  forTrack:self.playlistController.currentTrack];
    }
    // NSUndoManager's own state and titles, never a stat; an emptied Trash
    // surfaces only when the restore runs.
    else if ([menuItem.identifier isEqualToString:@"menu_edit_undo"]) {
        menuItem.title = self.window.undoManager.undoMenuItemTitle;
        return self.window.undoManager.canUndo;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_edit_redo"]) {
        menuItem.title = self.window.undoManager.redoMenuItemTitle;
        return self.window.undoManager.canRedo;
    }
    // The Copy items act on the current track, like Show in Finder.
    else if ([menuItem.identifier isEqualToString:@"menu_edit_copy_file"]) {
        return self.playlistController.currentTrack.url != nil;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_edit_copy_name"]) {
        return self.playlistController.currentTrack != nil;
    }
    // A preference, not an action, so never disabled.
    else if ([menuItem.identifier isEqualToString:@"menu_convert_delete_original"]) {
        menuItem.state = StateForBOOL(Settings.deleteOriginalAfterConvert);
    }
    // show_clicked_track_in_finder, on the playlist's row context menu,
    // targets PlaylistController, which validates it.
    return YES;
}

// A plain helper, deliberately not named numberOfItemsInMenu:. That selector
// is NSMenuDelegate's opt-in to incremental menu population, which requires
// the menu:updateItem:atIndex:shouldCancel: companion this class does not
// implement, and it would return 0 for every other delegated menu.
- (NSInteger)waveformStyleMenuItemCount {
    return self.waveformView.availableWaveformStyles.count;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if ([menu.identifier isEqualToString:@"waveform_style"]) {
        NSInteger count = [self waveformStyleMenuItemCount];
        while ([menu numberOfItems] < count)
            [menu insertItem:[NSMenuItem new] atIndex:0];
        while ([menu numberOfItems] > count)
            [menu removeItemAtIndex:0];
        // Sort by localized display name; localizedStandardCompare: keeps
        // x2/x4/x8 in numeric order.
        AudioWaveformView *waveformView = self.waveformView;
        NSArray<NSString *> *styles = [waveformView.availableWaveformStyles sortedArrayUsingComparator:
                ^NSComparisonResult(NSString *a, NSString *b) {
                    return [[waveformView displayNameForStyle:a] localizedStandardCompare:[waveformView displayNameForStyle:b]];
                }];
        for (NSUInteger i = 0; i < count; ++i) {
            NSMenuItem *item = [menu itemAtIndex:i];
            NSString *identifier = styles[i];
            item.title = [waveformView displayNameForStyle:identifier];
            // The identifier travels on the item — a localized title can't
            // round-trip into NSUserDefaults — and gives click_menu a stable id.
            item.representedObject = identifier;
            item.identifier = [@"waveform_style_" stringByAppendingString:identifier];
            item.state = StateForBOOL([identifier isEqualToString:waveformView.currentWaveformStyle]);
            item.enabled = YES;
            item.target = self;
            item.action = @selector(setWaveformStyle:);
        }
    }
}

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate:, a full
// submenu rebuild, on every keyDown. OutputDevicesMenuController follows the
// same pattern. The style items carry no key equivalents.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (IBAction)setWaveformStyle:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        [self applyWaveformStyle:((NSMenuItem *)sender).representedObject];
    }
}

- (NSArray<NSString *> *)availableWaveformStyleIdentifiers {
    return self.waveformView.availableWaveformStyles;
}

- (NSString *)displayNameForWaveformStyle:(NSString *)identifier {
    return [self.waveformView displayNameForStyle:identifier];
}

- (void)applyWaveformStyle:(NSString *)identifier {
    if (!identifier) {
        return;
    }
    self.waveformView.waveformStyle = identifier;
    Settings.waveformStyle = identifier;
}

@end
