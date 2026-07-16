//
//  MainPlayerController+Menus.m
//  Vibe
//

#import "MainPlayerController+Menus.h"
#import "MainWindow.h"
#import "PlaylistManager.h"
#import "AudioTrack.h"
#import "AudioWaveformView.h"

// waveformView and playlistTableView are synthesized by the class extension in
// MainPlayerController.m; re-declared readonly here (same pattern as
// MainPlayerController+Debug.h) so the waveform-style submenu code and the
// playlist context-menu validation can read them.
@interface MainPlayerController (MenuOutlets)
@property (weak, readonly) AudioWaveformView *waveformView;
@property (weak, readonly) NSTableView *playlistTableView;
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
        return self.playlistManager.hasNextTrack;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_previous_track"]) {
        return self.playlistManager.hasPreviousTrack;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_skip_forward"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_forward_more"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_forward_most"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back_more"] ||
             [menuItem.identifier isEqualToString:@"menu_skip_back_most"]) {
        // Seeking needs a loaded track; the skip is a no-op otherwise.
        return self.playlistManager.currentTrack != nil;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_low_kill"]) {
        menuItem.state = StateForBOOL(self.audioPlayer.lowKillEnabled);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_8"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 8);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_16"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 16);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_play"]) {
        // The action is playPause: — mirror the toggle in the title like
        // standard macOS players (isPlaying covers Loading: a play is
        // committed, so the available action is Pause).
        menuItem.title = self.audioPlayer.isPlaying ? @"Pause" : @"Play";
        return self.playlistManager.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"show_in_finder"]) {
        return self.playlistManager.currentTrack.url != nil;
    }
    else if ([menuItem.identifier isEqualToString:@"show_clicked_track_in_finder"]) {
        // Right-click on the table's empty area still opens the menu, with
        // clickedRow -1.
        NSInteger row = self.playlistTableView.clickedRow;
        return row >= 0 && row < (NSInteger)self.playlistManager.count;
    }
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
        NSArray<NSString*>* styles = [self.waveformView.availableWaveformStyles sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSUInteger i = 0; i < count; ++i) {
            NSMenuItem *item = [menu itemAtIndex:i];
            item.title = styles[i];
            item.state = StateForBOOL([item.title isEqualToString:self.waveformView.currentWaveformStyle]);
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
        NSString *title = ((NSMenuItem *)sender).title;
        self.waveformView.waveformStyle = title;
        Settings.waveformStyle = title;
    }
}

@end
