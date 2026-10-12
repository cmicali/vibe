//
//  DebugMacVerbs.m
//  Vibe
//
//  The mac verb table, which adds each topic's verbs after its own.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Playlist.h"
#import "DebugInfo.h"

#if DEBUG

#import "NowPlayingController+Debug.h"
#import "AppTheme.h"
#import "AudioTrack.h"
#import "NSView+DarkMode.h"

#pragma mark Command table

// Dispatch, the unknown-command reply and the client's per-verb wait all
// derive from this table, so an entry here or in a topic table is the entire
// app-side hookup.
NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSDictionary *> *own = @[
            // See DebugHealth.h. Reads the player's counts on its serial
            // queue, so a wedged queue times this out rather than answering
            // from stale state.
            VibeDebugCmd(@"dump_health", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugHealthJSON(controller);
            }),
            // Zeroes the cumulative render counters, so a measurement phase
            // reads on its own rather than as a delta.
            VibeDebugCmd(@"clear_render_counters", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                [controller.audioPlayer debugClearRenderCounters];
                return VibeJSONString(@{@"ok": @YES});
            }),
            // Sample dump_health right after it for a reading taken at rest.
            VibeDebugCmd(@"quiesce", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                VibeDebugQuiesce(controller, ^(NSString *response) {
                    VibeWriteDebugResponse(commandId, response);
                });
                return nil; // response written by the poll
            }),
            VibeDebugCmd(@"block_player <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double seconds = tokens.count == 2 ? tokens[1].doubleValue : -1;
                if (!isfinite(seconds) || seconds <= 0 || seconds > 10) return VibeErrorJSON(@"usage: block_player <seconds 0-10>");
                [controller.audioPlayer debugBlockQueueForSeconds:seconds];
                return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds)});
            }),
            VibeDebugCmd(@"dump_debug_info", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSDictionary *snapshot = VibeDebugInfoSnapshot(controller);
                AudioPlayer *player = controller.audioPlayer;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    NSString *text = VibeDebugInfoText(snapshot, player);
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"bytes": @([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), @"text": text,
                    }));
                });
                return nil;
            }),
            VibeDebugCmd(@"dump_now_playing_artwork", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Which image Now Playing's artwork was drawn from, by identity.
                NSImage *published = controller.nowPlayingController.debugPublishedArtwork;
                AudioTrack *track = controller.debugDisplayedTrack;
                AppTheme *theme = AppSettings.sharedInstance.currentTheme;
                NSString *dark = [theme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark] ?: @"";
                NSString *light = [theme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight] ?: @"";
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                if (!published) {
                    out[@"artwork"] = NSNull.null;
                }
                else if (published == track.cachedArt) {
                    out[@"artwork"] = @"art";
                }
                else if (published == track.cachedThumbnail) {
                    out[@"artwork"] = @"thumbnail";
                }
                else if (published == [AppTheme imageForReference:dark] || published == [AppTheme imageForReference:light]) {
                    BOOL isDark = published == [AppTheme imageForReference:dark];
                    BOOL isLight = published == [AppTheme imageForReference:light];
                    out[@"artwork"] = @"placeholder";
                    out[@"placeholderSide"] = isDark && isLight ? @"both" : isDark ? @"dark" : @"light";
                    out[@"placeholderReference"] = isDark ? dark : light; // "" is the factory image
                }
                else {
                    out[@"artwork"] = @"other";
                }
                out[@"windowAppearance"] = controller.window.effectiveAppearance.isDark ? @"dark" : @"light";
                return VibeJSONString(out);
            }),
            VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeViewTreeDump();
            }),
            VibeDebugCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(@{@"menu": VibeMenuArray(NSApp.mainMenu)});
            }),
            VibeDebugCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The arguments are the client's; see DebugClient.m.
                NSString *path = VibeDebugScreenshotPathForCommand(commandId);
                if (!VibeDumpWindowSnapshot(path)) {
                    return VibeErrorJSON(@"screenshot failed to render or write; see app log");
                }
                return VibeJSONString(@{@"path": path});
            }),
            // See DebugSettingsUI.h.
            VibeDebugCmd(@"settings_open [pane [light|dark|system]]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsOpen(tokens);
            }),
            VibeDebugCmd(@"settings_close", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsClose();
            }),
            VibeDebugCmd(@"dump_settings_ui", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsDump();
            }),
            VibeDebugCmd(@"settings_click <control> [value]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsClick(tokens);
            }),
            VibeDebugCmd(@"settings_reveal <control>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsReveal(tokens);
            }),
            VibeDebugCmd(@"settings_resize <width> <height>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsResize(tokens);
            }),
            VibeDebugCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
                }
                // The rest of the tokens, so titles with spaces work unquoted.
                return VibeClickMenuItem(controller, VibeRestArgument(tokens));
            }),
            VibeDebugCmd(@"open_url_window <text> | open | cancel | close", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: open_url_window <text> | open | cancel | close");
                }
                return VibeDriveOpenURLWindow(tokens);
            }),
            VibeTransportCmd(@"skip_forward", ^(MainPlayerController *controller) { [controller skipForward:nil]; }),
            VibeTransportCmd(@"skip_forward_more", ^(MainPlayerController *controller) { [controller skipForwardMore:nil]; }),
            VibeTransportCmd(@"skip_forward_most", ^(MainPlayerController *controller) { [controller skipForwardMost:nil]; }),
            VibeTransportCmd(@"skip_back", ^(MainPlayerController *controller) { [controller skipBack:nil]; }),
            VibeTransportCmd(@"skip_back_more", ^(MainPlayerController *controller) { [controller skipBackMore:nil]; }),
            VibeTransportCmd(@"skip_back_most", ^(MainPlayerController *controller) { [controller skipBackMost:nil]; }),
            VibeTransportCmd(@"toggle_pitch_panel", ^(MainPlayerController *controller) { [controller togglePitchPanel:nil]; }),
            // These bypass audioFXAllowed; inject key events to exercise the
            // shipping input gates.
            VibeTransportCmd(@"toggle_low_kill", ^(MainPlayerController *controller) { [controller toggleLowKill:nil]; }),
            VibeTransportCmd(@"reverb_send_on", ^(MainPlayerController *controller) { [controller setReverbSendActive:YES]; }),
            VibeTransportCmd(@"reverb_send_off", ^(MainPlayerController *controller) { [controller setReverbSendActive:NO]; }),
            VibeTransportCmd(@"delay_send_on", ^(MainPlayerController *controller) { [controller setDelaySendActive:YES]; }),
            VibeTransportCmd(@"delay_send_off", ^(MainPlayerController *controller) { [controller setDelaySendActive:NO]; }),
            VibeTransportCmd(@"short_delay_send_on", ^(MainPlayerController *controller) { [controller setShortDelaySendActive:YES]; }),
            VibeTransportCmd(@"short_delay_send_off", ^(MainPlayerController *controller) { [controller setShortDelaySendActive:NO]; }),
            VibeTransportCmd(@"low_kill_boost_on", ^(MainPlayerController *controller) { [controller setLowKillBoostActive:YES]; }),
            VibeTransportCmd(@"low_kill_boost_off", ^(MainPlayerController *controller) { [controller setLowKillBoostActive:NO]; }),
            VibeTransportCmd(@"toggle_size", ^(MainPlayerController *controller) { [controller toggleSize:nil]; }),
            VibeDebugCmd(@"set_controls_hover <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                BOOL shown;
                if (!VibeParseOnOff(tokens, &shown)) {
                    return VibeErrorJSON(@"usage: set_controls_hover <on|off>");
                }
                NSEvent *event = [NSEvent enterExitEventWithType:shown ? NSEventTypeMouseEntered : NSEventTypeMouseExited
                        location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:controller.window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
                if (shown) [controller.playerContentView mouseEntered:event];
                else [controller.playerContentView mouseExited:event];
                return VibeJSONString(@{@"ok": @YES, @"controlsHover": @(shown)});
            }),
            VibeDebugCmd(@"set_loading <off | indeterminate | fraction>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Both indicator modes, without a real slow cloud open.
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                double fraction = -1;
                if ([arg isEqualToString:@"off"]) {
                    [controller.trackDisplay hideWaveformLoadingIndicator];
                    return VibeJSONString(@{@"ok": @YES, @"loading": @"off"});
                }
                if (![arg isEqualToString:@"indeterminate"] && !VibeParseDouble(arg, &fraction)) {
                    return VibeErrorJSON(@"usage: set_loading <off | indeterminate | 0..1>");
                }
                [controller.trackDisplay showWaveformLoadingIndicator];
                [controller.trackDisplay setWaveformLoadingProgress:(float)fraction];
                return VibeJSONString(@{@"ok": @YES, @"fraction": @(fraction)});
            }),
            VibeDebugCmd(@"set_folder_art <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Writes and applies the setting as the Files pane's control does.
                BOOL on;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_folder_art <on|off>");
                }
                AppSettings.sharedInstance.useFolderArt = on;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectFolderArt];
                return VibeJSONString(@{@"ok": @YES, @"folderArt": @(AppSettings.sharedInstance.useFolderArt)});
            }),
            VibeDebugCmd(@"set_declick <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                BOOL on;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_declick <on|off>");
                }
                AppSettings.sharedInstance.declick = on;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectDeclick];
                return VibeJSONString(@{@"ok": @YES, @"declick": @(AppSettings.sharedInstance.declick)});
            }),
            VibeDebugCmd(@"set_reopen_playlist <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                BOOL on;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_reopen_playlist <on|off>");
                }
                AppSettings.sharedInstance.reopenLastPlaylist = on;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectReopenLastPlaylist];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"reopenLastPlaylist": @(AppSettings.sharedInstance.reopenLastPlaylist),
                });
            }),
            VibeDebugCmd(@"select_rows all|none|<row|current> [row|current ...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSelectPlaylistRows(controller, tokens);
            }),
            VibeDebugCmd(@"remove_selected", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count != 1) return VibeErrorJSON(@"usage: remove_selected");
                [controller removeSelectedPlaylistTracks:nil];
                return VibeJSONString(controller.debugActionSummary);
            }),
            VibeDebugCmd(@"gesture_test pitch-reset|pitch-drag isolated-desktop", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeTestGesture(controller, tokens);
            }),
            VibeDebugCmd(@"click <x> <y> [left|right] [clickCount]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeDebugCmd(@"mouse_down <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeDebugCmd(@"mouse_up <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeDebugCmd(@"mouse_move <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeDebugCmd(@"file_drag_hover <x> <y>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticFileDragHover(controller, tokens);
            }),
            VibeDebugCmd(@"file_drag_drop <x> <y> <file-directory-or-link>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticFileDragDrop(controller, tokens);
            }),
            VibeDebugCmd(@"file_drag_end", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticFileDragEnd(controller);
            }),
            VibeDebugCmd(@"reorder_begin <row> [row ...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeReorderBegin(controller, tokens);
            }),
            VibeDebugCmd(@"reorder_update <slot>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeReorderUpdate(controller, tokens);
            }),
            VibeDebugCmd(@"reorder_drop <slot>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeReorderDrop(controller, tokens);
            }),
            VibeDebugCmd(@"reorder_cancel", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeReorderCancel(controller);
            }),
            VibeDebugCmd(@"drag <x1> <y1> <x2> <y2> [steps]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectDrag(controller, tokens);
            }),
            VibeDebugCmd(@"key <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, YES, YES);
            }),
            VibeDebugCmd(@"key_down <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, YES, NO);
            }),
            VibeDebugCmd(@"key_up <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, NO, YES);
            }),
            VibeDebugCmd(@"set_shortcut <identifier> <key|none> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSetShortcut(controller, tokens);
            }),
            VibeDebugCmd(@"reset_shortcuts", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeResetShortcuts(controller);
            }),
            VibeDebugCmd(@"set_pitch <percent>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double percent = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &percent)) {
                    return VibeErrorJSON(@"usage: set_pitch <percent>");
                }
                // Through the panel first, so the fader clamps as a drag would.
                controller.pitchPanel.pitch = (float)percent;
                controller.audioPlayer.pitch = controller.pitchPanel.pitch;
                [controller debugRefreshUI];
                return VibeJSONString(controller.debugActionSummary);
            }),
            // The CLI client runs the scans locally, so these serve the usage
            // listing and callers that post the command file directly.
            VibeDebugCmd(@"scan_bpm <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // A full-file decode: off the main thread.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    VibeWriteDebugResponse(commandId, VibeDebugBPMScanJSON(path));
                });
                return nil; // response written by the block above
            }),
            VibeDebugCmd(@"scan_key <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    VibeWriteDebugResponse(commandId, VibeDebugKeyScanJSON(path));
                });
                return nil; // response written by the block above
            }),
            // The path must be writable by the sandboxed app (the container's
            // tmp, or a granted folder).
            VibeDebugCmd(@"save_playlist <path>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: save_playlist <path>");
                }
                NSUInteger count = controller.playlistController.count;
                if (count == 0) {
                    return VibeErrorJSON(@"playlist is empty");
                }
                NSString *path = VibePathArgument(tokens);
                NSError *error = nil;
                if (![controller writePlaylistToURL:[NSURL fileURLWithPath:path isDirectory:NO] error:&error]) {
                    return VibeErrorJSON(@"save failed: %@", error.localizedDescription);
                }
                return VibeJSONString(@{@"ok": @YES, @"path": path, @"tracks": @(count)});
            }),
            VibeDebugCmd(@"dump_last_playlist", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(controller.debugLastPlaylistDictionary);
            }),
        ];
        table = [[[[own arrayByAddingObjectsFromArray:VibeDebugThemeVerbs()]
                arrayByAddingObjectsFromArray:VibeDebugWindowVerbs()]
                arrayByAddingObjectsFromArray:VibeDebugOutputVerbs()]
                arrayByAddingObjectsFromArray:VibeDebugConvertVerbs()];
    });
    return table;
}

#endif
