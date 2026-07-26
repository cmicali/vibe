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
#import "Strings.h"

// waveformView is synthesized by the class extension in MainPlayerController.m;
// re-declared readonly here (same pattern as MainPlayerController+Debug.h) so
// the waveform-style submenu code can read it.
@interface MainPlayerController (MenuOutlets)
@property (weak, readonly) AudioWaveformView *waveformView;
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
        // Only when there is actually a track after the current one; at the
        // end of the playlist next: is a no-op.
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
        // Needs a loaded track AND a non-stopped player — after the playlist
        // ends there is no node left to seek (see skipByFileSeconds:).
        return self.playlistController.currentTrack != nil && !self.audioPlayer.isStopped;
    }
    // FX: one checkmark per effect. Never disabled — the effects are deck
    // controls that outlive any single track (see the FX menu in
    // MainMenuBuilder).
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
        // The action is playPause: — mirror the toggle in the title and icon
        // like standard macOS players (isPlaying covers Loading: a play is
        // committed, so the available action is Pause).
        BOOL playing = self.audioPlayer.isPlaying;
        menuItem.title = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
        menuItem.image = [NSImage imageWithSystemSymbolName:(playing ? @"pause.fill" : @"play.fill")
                                   accessibilityDescription:menuItem.title];
        return self.playlistController.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_close"]) {
        menuItem.title = self.playlistController.count > 1 ? STR_MENU_FILE_CLOSE_ALL : STR_MENU_FILE_CLOSE;
        return self.playlistController.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"show_in_finder"]) {
        return self.playlistController.currentTrack.url != nil;
    }
    // show_clicked_track_in_finder (the playlist row context menu) targets
    // PlaylistController, which validates it.
    return YES;
}

// Plain helper, deliberately NOT named numberOfItemsInMenu: — that selector
// is NSMenuDelegate's opt-in to incremental menu population, which requires
// the menu:updateItem:atIndex:shouldCancel: companion this class doesn't
// implement (and would return 0 for every other delegated menu).
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

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate: — a full
// submenu rebuild — on every keyDown (same pattern as
// OutputDevicesMenuController). The style items carry no key equivalents.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

- (IBAction)setWaveformStyle:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        NSString *identifier = ((NSMenuItem *)sender).representedObject;
        self.waveformView.waveformStyle = identifier;
        Settings.waveformStyle = identifier;
    }
}

@end
