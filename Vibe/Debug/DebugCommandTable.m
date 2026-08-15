//
//  DebugCommandTable.m
//  Vibe
//
//  The verb table. One entry per command, with its usage string and client timeout.
//

#import "DebugInternal.h"

#if DEBUG

#pragma mark Command table

// The first word of usage is the verb. clientTimeout is how long the CLI
// client waits for this verb's response, in seconds, where 0 means the
// default; see VibeDebugCommandClientMain.
static NSDictionary *VibeCmd(NSString *usage, NSTimeInterval clientTimeout, VibeDebugCommandHandler handler) {
    return @{@"usage": usage, @"clientTimeout": @(clientTimeout), @"handler": [handler copy]};
}

// The transport and toggle verbs: invoke the controller action, then reply
// with the compact action summary.
static NSDictionary *VibeActionCmd(NSString *usage, void (^action)(MainPlayerController *controller)) {
    return VibeCmd(usage, 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
        action(controller);
        return VibeActionSummary(controller);
    });
}

// The undo and redo verbs. A conversion's file moves settle after the manager
// call returns, so the reply waits on the controller's one-shot settled hook
// rather than racing the Trash; a reply outliving the client's timeout writes
// one orphan response and cannot fire on a later menu-driven undo.
static NSString *VibeRunUndoRedoCommand(NSString *commandId, MainPlayerController *controller, BOOL redo) {
    NSUndoManager *undoManager = controller.window.undoManager;
    if (controller.isConversionUndoRedoInFlight) {
        return VibeErrorJSON(@"conversion undo/redo is still in progress");
    }
    if (redo ? !undoManager.canRedo : !undoManager.canUndo) {
        return VibeErrorJSON(redo ? @"nothing to redo" : @"nothing to undo");
    }
    NSString *actionName = redo ? undoManager.redoActionName : undoManager.undoActionName;
    controller.conversionUndoRedoSettledHandler = ^{
        VibeWriteDebugResponse(commandId, VibeJSONString(@{
            @"ok": @YES,
            (redo ? @"redid" : @"undid"): actionName ?: @"",
            @"canUndo": @(undoManager.canUndo),
            @"canRedo": @(undoManager.canRedo),
        }));
    };
    if (redo) {
        [controller redo:nil];
    }
    else {
        [controller undo:nil];
    }
    return nil; // response written by the settled hook
}

// The command set. Dispatch, the unknown-command usage reply and the client's
// per-verb wait all derive from this table, so adding an entry here is the
// entire app-side hookup. The usage docs live in the vibe-debug skill.
NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeCmd(@"dump_state", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(VibeStateDictionary(controller));
            }),
            VibeCmd(@"dump_now_playing", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The state we publish to the system Now Playing UI, in
                // Control Center and to the media keys. It cross-checks the
                // NowPlayingController wiring without a private-framework
                // reader.
                MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
                NSDictionary *info = center.nowPlayingInfo;
                MPNowPlayingPlaybackState playbackState = center.playbackState;
                NSString *stateName = playbackState == MPNowPlayingPlaybackStatePlaying ? @"playing"
                        : playbackState == MPNowPlayingPlaybackStatePaused ? @"paused"
                        : playbackState == MPNowPlayingPlaybackStateStopped ? @"stopped"
                        : @"unknown";
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playbackState"] = stateName;
                out[@"hasInfo"] = @(info != nil);
                if (info) {
                    out[@"title"] = info[MPMediaItemPropertyTitle] ?: NSNull.null;
                    out[@"artist"] = info[MPMediaItemPropertyArtist] ?: NSNull.null;
                    out[@"duration"] = info[MPMediaItemPropertyPlaybackDuration] ?: NSNull.null;
                    out[@"elapsed"] = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?: NSNull.null;
                    out[@"rate"] = info[MPNowPlayingInfoPropertyPlaybackRate] ?: NSNull.null;
                    out[@"hasArtwork"] = @(info[MPMediaItemPropertyArtwork] != nil);
                }
                return VibeJSONString(out);
            }),
            VibeCmd(@"dump_stats", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                AppStats *stats = [AppStats sharedInstance];
                return VibeJSONString(@{
                    @"filesOpened": @(stats.totalFilesOpened),
                    @"foldersOpened": @(stats.totalFoldersOpened),
                    @"secondsPlayed": @(stats.totalSecondsPlayed),
                });
            }),
            // The stress driver's two oracles; see DebugHealth.h. dump_health
            // and check_invariants both reach the player's serial queue for
            // the engine node count, so a wedged queue times them out rather
            // than letting them answer from stale state.
            VibeCmd(@"dump_health", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugHealthJSON(controller);
            }),
            VibeCmd(@"check_invariants", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugInvariantsJSON(controller);
            }),
            // Async: it closes the file and then polls for the pending
            // counters to unwind, so the response arrives from the poll rather
            // than from here. Sample dump_health right after it for a reading
            // taken at rest instead of mid-decode.
            VibeCmd(@"quiesce", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                VibeDebugQuiesce(controller, ^(NSString *response) {
                    VibeWriteDebugResponse(commandId, response);
                });
                return nil; // response written by the poll
            }),
            VibeCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeViewTreeDump();
            }),
            VibeCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(@{@"menu": VibeMenuArray(NSApp.mainMenu)});
            }),
            VibeCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The arguments are client-side. "-" streams the PNG bytes to
                // stdout, and inside a script the reply carries the PNG as
                // base64, with a label naming the decoded file; see
                // run-script.sh.
                NSString *path = VibeDebugScreenshotPathForCommand(commandId);
                if (!VibeDumpWindowSnapshot(path)) {
                    return VibeErrorJSON(@"screenshot failed to render or write; see app log");
                }
                return VibeJSONString(@{@"path": path});
            }),
            // The settings window: a second window the injection verbs below
            // cannot reach, since they all post into the player's event
            // stream. DebugSettingsUI.m addresses its controls by name.
            VibeCmd(@"settings_open [pane]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsOpen(tokens);
            }),
            VibeCmd(@"settings_close", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsClose();
            }),
            VibeCmd(@"dump_settings_ui", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsDump();
            }),
            VibeCmd(@"settings_click <control> [value]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsClick(tokens);
            }),
            VibeCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
                }
                // The rest of the tokens, so exact titles with spaces work too.
                return VibeClickMenuItem(VibeRestArgument(tokens));
            }),
            VibeActionCmd(@"play_pause", ^(MainPlayerController *controller) { [controller playPause:nil]; }),
            VibeActionCmd(@"next", ^(MainPlayerController *controller) { [controller next:nil]; }),
            VibeActionCmd(@"previous", ^(MainPlayerController *controller) { [controller previous:nil]; }),
            VibeActionCmd(@"skip_forward", ^(MainPlayerController *controller) { [controller skipForward:nil]; }),
            VibeActionCmd(@"skip_forward_more", ^(MainPlayerController *controller) { [controller skipForwardMore:nil]; }),
            VibeActionCmd(@"skip_forward_most", ^(MainPlayerController *controller) { [controller skipForwardMost:nil]; }),
            VibeActionCmd(@"skip_back", ^(MainPlayerController *controller) { [controller skipBack:nil]; }),
            VibeActionCmd(@"skip_back_more", ^(MainPlayerController *controller) { [controller skipBackMore:nil]; }),
            VibeActionCmd(@"skip_back_most", ^(MainPlayerController *controller) { [controller skipBackMost:nil]; }),
            VibeActionCmd(@"toggle_pitch_panel", ^(MainPlayerController *controller) { [controller togglePitchPanel:nil]; }),
            VibeActionCmd(@"toggle_low_kill", ^(MainPlayerController *controller) { [controller toggleLowKill:nil]; }),
            VibeActionCmd(@"reverb_send_on", ^(MainPlayerController *controller) { [controller setReverbSendActive:YES]; }),
            VibeActionCmd(@"reverb_send_off", ^(MainPlayerController *controller) { [controller setReverbSendActive:NO]; }),
            VibeActionCmd(@"delay_send_on", ^(MainPlayerController *controller) { [controller setDelaySendActive:YES]; }),
            VibeActionCmd(@"delay_send_off", ^(MainPlayerController *controller) { [controller setDelaySendActive:NO]; }),
            VibeActionCmd(@"short_delay_send_on", ^(MainPlayerController *controller) { [controller setShortDelaySendActive:YES]; }),
            VibeActionCmd(@"short_delay_send_off", ^(MainPlayerController *controller) { [controller setShortDelaySendActive:NO]; }),
            VibeActionCmd(@"low_kill_boost_on", ^(MainPlayerController *controller) { [controller setLowKillBoostActive:YES]; }),
            VibeActionCmd(@"low_kill_boost_off", ^(MainPlayerController *controller) { [controller setLowKillBoostActive:NO]; }),
            VibeActionCmd(@"toggle_size", ^(MainPlayerController *controller) { [controller toggleSize:nil]; }),
            VibeCmd(@"set_loading <off | indeterminate | fraction>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Drives the loading indicator directly, so both of its modes
                // can be captured without a real slow cloud open — which is
                // otherwise the only way in, and is unreproducible by nature.
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
            VibeCmd(@"set_folder_art <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Writes the setting and applies it live, as the Settings >
                // Files control does; the pane itself cannot be driven from
                // here.
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                if (![arg isEqualToString:@"on"] && ![arg isEqualToString:@"off"]) {
                    return VibeErrorJSON(@"usage: set_folder_art <on|off>");
                }
                Settings.useFolderArt = [arg isEqualToString:@"on"];
                [controller refreshFolderArt];
                return VibeJSONString(@{@"ok": @YES, @"folderArt": @(Settings.useFolderArt)});
            }),
            VibeCmd(@"set_window_width <body-points>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double bodyPoints = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &bodyPoints)) {
                    return VibeErrorJSON(@"usage: set_window_width <body-points>");
                }
                // The window is freely resizable and its width comes back from
                // the frame autosave, so a screenshot run that wants a
                // reproducible size must set one. The argument is the body
                // width: the player without the pitch panel's slice, which is
                // what MainPlayerContentView lays out at and what
                // kMainWindowContentWidth names. The number therefore means
                // the same thing whether or not the panel happens to be out.
                MainWindow *window = (MainWindow *)controller.window;
                CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
                NSRect frame = window.frame;
                // It grows to the right like a resize-handle drag, floored by
                // the window's own minSize, which already carries the panel,
                // then is pulled back on screen: a window hanging off the
                // right edge captures clipped.
                frame.size.width = MAX(window.minSize.width, bodyPoints + panel);
                NSRect screenRect = window.screen.visibleFrame;
                if (screenRect.size.width > 0 && NSMaxX(frame) > NSMaxX(screenRect)) {
                    frame.origin.x = MAX(NSMinX(screenRect), NSMaxX(screenRect) - frame.size.width);
                }
                [window setFrame:frame display:YES];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"frame": NSStringFromRect(window.frame),
                    @"bodyWidth": @(window.frame.size.width - panel),
                });
            }),
            VibeCmd(@"click <x> <y> [left|right] [clickCount]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeCmd(@"mouse_down <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeCmd(@"mouse_up <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeCmd(@"mouse_move <x> <y> [left|right]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectMouse(controller, tokens);
            }),
            VibeCmd(@"drag_hover <x> <y>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticDragHover(controller, tokens);
            }),
            VibeCmd(@"drag_drop <x> <y> <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticDragDrop(controller, tokens);
            }),
            VibeCmd(@"drag_end", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeSyntheticDragEnd(controller);
            }),
            VibeCmd(@"drag <x1> <y1> <x2> <y2> [steps]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectDrag(controller, tokens);
            }),
            VibeCmd(@"key <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, YES, YES);
            }),
            VibeCmd(@"key_down <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, YES, NO);
            }),
            VibeCmd(@"key_up <key> [mods...]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeInjectKey(controller, tokens, NO, YES);
            }),
            VibeCmd(@"set_pitch <percent>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double percent = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &percent)) {
                    return VibeErrorJSON(@"usage: set_pitch <percent>");
                }
                // Through the panel first, so that the fader clamps to its
                // range exactly as a drag would, and then the player takes the
                // clamped value.
                controller.pitchPanel.pitch = (float)percent;
                controller.audioPlayer.pitch = controller.pitchPanel.pitch;
                [controller debugRefreshUI];
                return VibeActionSummary(controller);
            }),
            VibeCmd(@"seek <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds)) {
                    return VibeErrorJSON(@"usage: seek <seconds>");
                }
                [controller.audioPlayer seekToPosition:seconds];
                [controller debugRefreshUI];
                return VibeActionSummary(controller);
            }),
            VibeCmd(@"open <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: open <file-or-directory>");
                }
                NSString *path = VibePathArgument(tokens);
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no file or directory at '%@'", path);
                }
                // The same expand, filter and play pipeline as a Finder open
                // or a file drop: a directory is walked and unsupported files
                // are dropped. It is async, because a large folder walk should
                // not stall the channel, so the reply only acks the request;
                // poll `dump_state` for the resulting playlist. On the
                // sandbox: an arbitrary path the app has not been granted may
                // be denied at read time, the same caveat as with command-line
                // arguments, and `open -a "$APP"` grants access.
                [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                                    completion:^(NSArray<NSURL *> *expanded, NSUInteger folderCount) {
                    if (expanded.count > 0) {
                        [controller play:expanded];
                    }
                }];
                return VibeJSONString(@{@"ok": @YES, @"opening": path});
            }),
            // These are normally never reached from the CLI, because the
            // client runs scan_bpm and scan_key locally; see
            // VibeDebugCommandClientMain. The entries exist for the usage
            // listing and for callers that post the command file directly.
            // They are the same core functions either way.
            VibeCmd(@"scan_bpm <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // A full-file decode, so keep it off the main thread.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    VibeWriteDebugResponse(commandId, VibeDebugBPMScanJSON(path));
                });
                return nil; // response written by the block above
            }),
            // The in-process phase timings of recent waveform decodes, newest
            // first — every load, whether it came from playing a track or from
            // file_cache. This is the accurate measure of what the BPM and key
            // analyzers cost: the app's total CPU also carries the render pump,
            // the metadata scan and the UI.
            VibeCmd(@"dump_timing", 5, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(@{@"loads": [AudioLoadTiming recentJSON]});
            }),
            VibeCmd(@"clear_timing", 5, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                [AudioLoadTiming reset];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeCmd(@"scan_key <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeCmd(@"file_cache <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // Decode and persist this file's waveform without disturbing
                // the current load, then reply with its detected BPM and key
                // once the entry is on disk. A cold decode of a long file
                // runs well past the default client wait, hence this verb's
                // 60-second clientTimeout.
                [controller.waveformCache cacheWaveformForURL:[NSURL fileURLWithPath:path]
                                                   completion:^(BOOL ok, BOOL wasCached, float bpm, NSInteger key) {
                    // The decode's own phase timings, measured in-process, or
                    // absent on a cache hit, where no decode ran.
                    NSDictionary *timing = [AudioLoadTiming newestJSONForPath:path];
                    NSMutableDictionary *body = [@{@"ok": @YES, @"path": path, @"wasCached": @(wasCached),
                                                   @"bpm": @(bpm), @"key": VibeMusicalKeyMusicalName(key),
                                                   @"camelot": VibeMusicalKeyCamelotName(key)} mutableCopy];
                    if (timing && !wasCached) {
                        body[@"timing"] = timing;
                    }
                    NSString *reply = ok ? VibeJSONString(body)
                            : VibeErrorJSON(@"waveform decode failed for '%@'", path);
                    VibeWriteDebugResponse(commandId, reply);
                }];
                return nil; // response written by the completion above
            }),
            // The whole Convert to FLAC path on the current track, swap and
            // disposal included. The optional keep|delete token writes
            // Convert > Delete Original, as the menu item does, and leaves it
            // written — applied only once the command will actually convert,
            // so a usage error or missing track mutates nothing. The
            // 120-second clientTimeout covers a long encode.
            VibeCmd(@"convert_to_flac [keep|delete]", 120, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *mode = tokens.count > 1 ? tokens[1].lowercaseString : nil;
                if (tokens.count > 2 ||
                        (mode && !([mode isEqualToString:@"keep"] || [mode isEqualToString:@"delete"]))) {
                    return VibeErrorJSON(@"usage: convert_to_flac [keep|delete]");
                }
                AudioTrack *track = controller.playlistController.currentTrack;
                if (!track) {
                    return VibeErrorJSON(@"no track to convert");
                }
                if (mode) {
                    Settings.deleteOriginalAfterConvert = [mode isEqualToString:@"delete"];
                }
                // Read before the swap replaces the track; reported back so a
                // test can assert the deletion without reading the Trash,
                // which TCC denies a terminal.
                NSString *sourcePath = track.url.path;
                [controller convertTrackToFLAC:track
                                    completion:^(NSURL *outputURL, BOOL sourceDeleted, NSError *error) {
                    if (!outputURL) {
                        VibeWriteDebugResponse(commandId,
                                VibeErrorJSON(@"convert failed: %@", error.localizedDescription));
                        return;
                    }
                    AudioTrack *swapped = [controller.playlistController trackForURL:outputURL];
                    // The completion runs after the disposal settles, so this
                    // stat is a verdict, not a race.
                    BOOL sourceRemains = [NSFileManager.defaultManager fileExistsAtPath:sourcePath];
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"ok": @YES,
                        @"output": outputURL.path,
                        @"row": @([controller.playlistController getIndexForTrack:swapped]),
                        @"source": sourcePath ?: @"",
                        @"sourceDeleted": @(sourceDeleted),
                        @"sourceRemains": @(sourceRemains),
                    }));
                }];
                return nil; // response written by the completion above
            }),
            VibeCmd(@"undo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, NO);
            }),
            VibeCmd(@"redo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, YES);
            }),
            VibeCmd(@"file_clear_cache <file>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                [controller.waveformCache clearCachedWaveformForURL:[NSURL fileURLWithPath:path]
                                                         completion:^(BOOL wasPresent) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"ok": @YES, @"path": path, @"wasPresent": @(wasPresent),
                    }));
                }];
                return nil; // response written by the completion above
            }),
            // A clientTimeout of 20 exceeds the app-side 15-second
            // dispatch_group_wait. The waveform clear queues behind any
            // in-flight waveform load, and a flat 5-second client wait could
            // give up on a clear that then succeeds.
            VibeCmd(@"clear_caches", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // This blocks the main thread until both PINCache stores are
                // empty, which is acceptable for a debug-only command: the
                // clears are file deletes at utility QoS.
                dispatch_group_t group = dispatch_group_create();
                dispatch_group_enter(group);
                [controller.metadataCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                dispatch_group_enter(group);
                [controller.waveformCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
                    return VibeErrorJSON(@"cache clear timed out after 15s");
                }
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"cleared": @[AudioTrackMetadataCache.cacheName, AudioWaveformCache.cacheName],
                });
            }),
            // Ending the app without a signal, which is the only way to end an
            // instance Xcode is debugging: an attached debugger traps SIGTERM
            // and stops the process instead of killing it, so a pkill leaves it
            // in the process table, answering nothing. This is also the only
            // exit that runs applicationWillTerminate:, so the AppStats flush
            // happens; SIGKILL loses it. The reply is written here because
            // nothing survives to write it afterwards, and terminate: is
            // deferred so the drain loop that called us finishes first.
            VibeCmd(@"quit", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                VibeWriteDebugResponse(commandId, VibeJSONString(@{@"ok": @YES, @"quitting": @YES}));
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSApp terminate:nil];
                });
                return nil; // written above, before the app goes away
            }),
        ];
    });
    return table;
}

#endif
