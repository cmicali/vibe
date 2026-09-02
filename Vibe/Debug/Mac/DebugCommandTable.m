//
//  DebugCommandTable.m
//  Vibe
//
//  The verb table. One entry per command, with its usage string and client timeout.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "AudioTrackMetadata.h"
#import "FLACConvertRules.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

#if DEBUG

#pragma mark Command table

// The undo and redo verbs. A conversion's file moves settle after the manager
// call returns, so the reply waits on the controller's one-shot settled hook
// rather than racing the Trash; a reply outliving the client's timeout writes
// one orphan response and cannot fire on a later menu-driven undo. A
// non-conversion undo — a playlist removal's restore — settles inside the
// manager call and never fires that hook, so the post-call check answers it
// synchronously instead of timing the client out.
static NSString *VibeRunUndoRedoCommand(NSString *commandId, MainPlayerController *controller, BOOL redo) {
    NSUndoManager *undoManager = controller.window.undoManager;
    if (controller.isConversionUndoRedoInFlight) {
        return VibeErrorJSON(@"conversion undo/redo is still in progress");
    }
    if (redo ? !undoManager.canRedo : !undoManager.canUndo) {
        return VibeErrorJSON(redo ? @"nothing to redo" : @"nothing to undo");
    }
    NSString *actionName = redo ? undoManager.redoActionName : undoManager.undoActionName;
    void (^settled)(BOOL, NSString *) = ^(BOOL committed, NSString *reason) {
        NSMutableDictionary *response = [@{
            @"ok": @YES,
            (redo ? @"redid" : @"undid"): actionName ?: @"",
            @"committed": @(committed),
            @"canUndo": @(undoManager.canUndo),
            @"canRedo": @(undoManager.canRedo),
        } mutableCopy];
        if (reason) {
            response[@"reason"] = reason;
        }
        VibeWriteDebugResponse(commandId, VibeJSONString(response));
    };
    controller.conversionUndoRedoSettledHandler = settled;
    if (redo) {
        [controller redo:nil];
    }
    else {
        [controller undo:nil];
    }
    // The hook is one-shot and clears itself as it fires. Still installed with
    // no conversion transaction running means this undo never was a
    // conversion's: it settled synchronously, so fire the same reply now.
    if (controller.conversionUndoRedoSettledHandler
            && !controller.isConversionUndoRedoInFlight) {
        controller.conversionUndoRedoSettledHandler = nil;
        settled(YES, nil);
    }
    return nil; // response written by the settled block
}

// A theme by stable id or display name (case-insensitive); nil when it names
// nothing. Shared by set_theme and dump_theme.
static NSString *VibeThemeIdentifierMatching(NSString *query) {
    for (NSString *identifier in AppSettings.sharedInstance.orderedThemeIdentifiers) {
        NSString *name = [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier];
        if ([identifier isEqualToString:query] ||
            [name caseInsensitiveCompare:query] == NSOrderedSame) {
            return identifier;
        }
    }
    return nil;
}

// The command set. Dispatch, the unknown-command usage reply and the client's
// per-verb wait all derive from this table, so adding an entry here is the
// entire app-side hookup. The usage docs live in the vibe-debug skill.
NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // The stress driver's two oracles; see DebugHealth.h. dump_health
            // and check_consistency (shared table) both reach the player's
            // serial queue for the engine node count, so a wedged queue times
            // them out rather than letting them answer from stale state.
            VibeDebugCmd(@"dump_health", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugHealthJSON(controller);
            }),
            // Async: it closes the file and then polls for the pending
            // counters to unwind, so the response arrives from the poll rather
            // than from here. Sample dump_health right after it for a reading
            // taken at rest instead of mid-decode.
            VibeDebugCmd(@"quiesce", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                VibeDebugQuiesce(controller, ^(NSString *response) {
                    VibeWriteDebugResponse(commandId, response);
                });
                return nil; // response written by the poll
            }),
            VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeViewTreeDump();
            }),
            VibeDebugCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(@{@"menu": VibeMenuArray(NSApp.mainMenu)});
            }),
            VibeDebugCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeDebugCmd(@"settings_open [pane]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeDebugCmd(@"settings_resize <width> <height>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeDebugSettingsResize(tokens);
            }),
            // Store-writing: many menu items write settings (appearance,
            // theme, Show File Info), and a scripted click never runs the
            // menu-tracking notification a real menu interaction refreshes
            // the panes through.
            VibeDebugCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
                }
                // The rest of the tokens, so exact titles with spaces work too.
                return VibeClickMenuItem(VibeRestArgument(tokens));
            }),
            VibeDebugCmd(@"append <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: append <file-or-directory>");
                }
                NSString *path = VibePathArgument(tokens);
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no file or directory at '%@'", path);
                }
                AppDelegate *delegate = (AppDelegate *)NSApp.delegate;
                if (![delegate isKindOfClass:AppDelegate.class]) {
                    return VibeErrorJSON(@"app delegate is not ready");
                }
                // Enter the actual deliberate-open funnel. The shared `open`
                // verb intentionally bypasses it so it can serve both shells.
                [delegate openDroppedURLs:@[[NSURL fileURLWithPath:path]] appending:YES];
                return VibeJSONString(@{@"ok": @YES, @"appending": path});
            }),
            VibeTransportCmd(@"skip_forward", ^(MainPlayerController *controller) { [controller skipForward:nil]; }),
            VibeTransportCmd(@"skip_forward_more", ^(MainPlayerController *controller) { [controller skipForwardMore:nil]; }),
            VibeTransportCmd(@"skip_forward_most", ^(MainPlayerController *controller) { [controller skipForwardMost:nil]; }),
            VibeTransportCmd(@"skip_back", ^(MainPlayerController *controller) { [controller skipBack:nil]; }),
            VibeTransportCmd(@"skip_back_more", ^(MainPlayerController *controller) { [controller skipBackMore:nil]; }),
            VibeTransportCmd(@"skip_back_most", ^(MainPlayerController *controller) { [controller skipBackMost:nil]; }),
            VibeTransportCmd(@"toggle_pitch_panel", ^(MainPlayerController *controller) { [controller togglePitchPanel:nil]; }),
            // Model-level FX drivers intentionally bypass audioFXEnabled; use
            // injected key events to exercise the shipping input gates.
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
            VibeDebugCmd(@"set_loading <off | indeterminate | fraction>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeDebugCmd(@"set_folder_art <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Writes the setting and applies it live, as the Settings >
                // Files control does; the pane itself cannot be driven from
                // here.
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                if (![arg isEqualToString:@"on"] && ![arg isEqualToString:@"off"]) {
                    return VibeErrorJSON(@"usage: set_folder_art <on|off>");
                }
                AppSettings.sharedInstance.useFolderArt = [arg isEqualToString:@"on"];
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectFolderArt];
                return VibeJSONString(@{@"ok": @YES, @"folderArt": @(AppSettings.sharedInstance.useFolderArt)});
            }),
            VibeDebugCmd(@"set_theme <id-or-name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_theme <id-or-name>");
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                [AppSettings.sharedInstance applyThemeWithIdentifier:match];
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
                return VibeJSONString(@{@"ok": @YES, @"activeTheme": match});
            }),
            VibeDebugCmd(@"remove_theme <id-or-name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: remove_theme <id-or-name>");
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                if ([AppTheme isBuiltInIdentifier:match]) {
                    return VibeErrorJSON(@"built-in themes cannot be removed: %@", match);
                }
                // Removing the active theme applies vibe in the store; the
                // apply effect makes that visible, as set_theme's does.
                BOOL wasActive = [AppSettings.sharedInstance.activeThemeIdentifier
                        isEqualToString:match];
                [AppSettings.sharedInstance removeUserThemeWithIdentifier:match fallingBackTo:nil];
                if (wasActive) {
                    [controller applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
                }
                return VibeJSONString(@{@"ok": @YES, @"removed": match,
                        @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
                        @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count)});
            }),
            // Inline JSON or a path the APP can read (the container, or a
            // granted folder) — the sandboxed open panel this bypasses is the
            // UI's business.
            VibeDebugCmd(@"import_theme <json|path>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: import_theme <json|path>");
                }
                NSData *data = [tokens[1] hasPrefix:@"{"]
                        ? [tokens[1] dataUsingEncoding:NSUTF8StringEncoding]
                        : [NSData dataWithContentsOfFile:tokens[1]];
                NSString *name = nil;
                NSError *error = nil;
                NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:data
                                                                         name:&name
                                                                        error:&error];
                if (!record) {
                    return VibeErrorJSON(@"not a theme: %@", error.localizedDescription ?: @"unreadable");
                }
                // The same default the Settings pane's import gives a file
                // that carried no name of its own.
                NSString *identifier = [AppSettings.sharedInstance addUserThemeWithRecord:record
                        name:(name.length ? name : STR_THEME_NAME_IMPORTED)];
                return VibeJSONString(@{@"ok": @YES, @"imported": identifier,
                        @"name": [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier],
                        @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count)});
            }),
            VibeDebugCmd(@"dump_theme [id-or-name]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeJSONString(@{@"ok": @YES,
                            @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
                            @"theme": AppSettings.sharedInstance.currentTheme.dictionaryRepresentation});
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                NSData *json = [AppTheme JSONDataForRecord:
                        [AppSettings.sharedInstance recordForThemeIdentifier:match]
                                                      name:[AppSettings.sharedInstance
                                                            displayNameForThemeIdentifier:match]];
                NSDictionary *record = [NSJSONSerialization JSONObjectWithData:json
                                                                       options:0 error:NULL];
                return VibeJSONString(@{@"ok": @YES, @"id": match, @"theme": record});
            }),
            // App-side, not a CLI-process prefs write: the key-label display
            // lives on the current theme, an in-memory object a cross-process
            // defaults write cannot reach.
            VibeDebugCmd(@"set_appearance <light|dark|system>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSDictionary<NSString *, NSString *> *values = @{
                    @"light": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT,
                    @"dark": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
                    @"system": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
                };
                // The empty string (system) is a present, non-nil value.
                NSString *value = tokens.count == 2 ? values[tokens[1].lowercaseString] : nil;
                if (!value) {
                    return VibeErrorJSON(@"usage: set_appearance <light|dark|system>");
                }
                AppSettings.sharedInstance.windowAppearanceStyle = value;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
                return VibeJSONString(@{@"ok": @YES, @"windowAppearance": tokens[1]});
            }),
            VibeDebugCmd(@"set_key_display <camelot|musical> <colors|plain>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSDictionary<NSString *, NSString *> *notations = @{
                    @"camelot": SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
                    @"musical": SETTINGS_VALUE_KEY_NOTATION_MUSICAL,
                };
                NSString *notation = tokens.count == 3 ? notations[tokens[1].lowercaseString] : nil;
                BOOL colorsOn = tokens.count == 3 && [tokens[2] isEqualToString:@"colors"];
                BOOL colorsOff = tokens.count == 3 && [tokens[2] isEqualToString:@"plain"];
                if (!notation || (!colorsOn && !colorsOff)) {
                    return VibeErrorJSON(@"usage: set_key_display <camelot|musical> <colors|plain>");
                }
                AppTheme *theme = AppSettings.sharedInstance.currentTheme;
                theme.keyNotation = notation;
                theme.keyColorsEnabled = colorsOn;
                [AppSettings.sharedInstance currentThemeDidChange];
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
                return VibeJSONString(@{@"ok": @YES, @"keyNotation": notation,
                                        @"keyColors": @(colorsOn)});
            }),
            VibeDebugCmd(@"set_pause_at_track_end <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                if (![arg isEqualToString:@"on"] && ![arg isEqualToString:@"off"]) {
                    return VibeErrorJSON(@"usage: set_pause_at_track_end <on|off>");
                }
                AppSettings.sharedInstance.pauseAtTrackEnd = [arg isEqualToString:@"on"];
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
                });
            }),
            VibeDebugCmd(@"set_window_width <body-points>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeDebugCmd(@"file_drag_drop <x> <y> <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            VibeDebugCmd(@"set_pitch <percent>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
                return VibeJSONString(controller.debugActionSummary);
            }),
            // These are normally never reached from the CLI, because the
            // client runs scan_bpm and scan_key locally; see
            // VibeDebugCommandClientMain. The entries exist for the usage
            // listing and for callers that post the command file directly.
            // They are the same core functions either way.
            VibeDebugCmd(@"scan_bpm <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
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
            // The whole Convert to FLAC path on the current track, swap and
            // disposal included. The optional keep|delete token writes Convert
            // > Delete Original, as the menu item does, and leaves it written.
            // omit-trash-url is a one-shot fault for the ambiguous successful
            // Trash result; applied only once the command will actually convert.
            // The 120-second clientTimeout covers a long encode. Store-writing
            // because [keep|delete] sets deleteOriginalAfterConvert, a Convert
            // pane row.
            VibeDebugCmd(@"convert_to_flac [keep|delete] [omit-trash-url]", 120, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *mode = tokens.count > 1 ? tokens[1].lowercaseString : nil;
                NSString *fault = tokens.count > 2 ? tokens[2].lowercaseString : nil;
                BOOL omitTrashURL = [fault isEqualToString:@"omit-trash-url"];
                if (tokens.count > 3 ||
                        (mode && !([mode isEqualToString:@"keep"] || [mode isEqualToString:@"delete"])) ||
                        (fault && !omitTrashURL) ||
                        (omitTrashURL && ![mode isEqualToString:@"delete"])) {
                    return VibeErrorJSON(@"usage: convert_to_flac [keep|delete] [omit-trash-url]");
                }
                AudioTrack *track = controller.playlistController.currentTrack;
                if (!track) {
                    return VibeErrorJSON(@"no track to convert");
                }
                // Refuse before touching the one-shot fault. Command handlers
                // may overlap while an earlier async conversion is running;
                // clearing or arming its hook here would change that request's
                // undo record. Mirror the converter's synchronous refusals so
                // an unaccepted request never leaves a fault awaiting some
                // later conversion either.
                if (controller.fileConverter.isConverting) {
                    return VibeErrorJSON(@"conversion already in progress");
                }
                if (!track.url.isFileURL ||
                        !VibeTrackIsConvertibleToFLAC(track.metadata.fileType,
                                                     track.url.pathExtension)) {
                    return VibeErrorJSON(@"current track is not convertible to FLAC");
                }
                if (mode) {
                    AppSettings.sharedInstance.deleteOriginalAfterConvert = [mode isEqualToString:@"delete"];
                }
                [controller.fileConverter debugClearPendingSourceTrashURLFault];
                id faultOwner = nil;
                if (omitTrashURL) {
                    faultOwner = [controller.fileConverter debugArmOmitNextSourceTrashURL];
                }
                // Read before the swap replaces the track; reported back so a
                // test can assert the deletion without reading the Trash,
                // which TCC denies a terminal.
                NSString *sourcePath = track.url.path;
                [controller convertTrackToFLAC:track
                                    completion:^(NSURL *outputURL, BOOL sourceDeleted, NSError *error) {
                    // Source disposal normally consumes this before starting
                    // its move. Cancel only if this request still owns a fault
                    // left pending by an earlier conversion failure.
                    if (faultOwner) {
                        [controller.fileConverter
                                debugCancelPendingSourceTrashURLFaultWithOwner:faultOwner];
                    }
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
            VibeDebugCmd(@"undo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, NO);
            }),
            VibeDebugCmd(@"redo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, YES);
            }),
        ];
    });
    return table;
}

#endif
