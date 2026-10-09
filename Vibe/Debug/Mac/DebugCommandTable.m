//
//  DebugCommandTable.m
//  Vibe
//
//  The mac verb table.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "AudioTrackMetadata.h"
#import "FLACConvertRules.h"
#import "MainPlayerController+Settings.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"
#import "DebugInfo.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"

#if DEBUG

#import "VibeWorkTally.h"
#import "NowPlayingController+Debug.h"
#import "AppTheme.h"
#import "AudioTrack.h"
#import "NSView+DarkMode.h"
#import <sys/resource.h>

#pragma mark Command table

// Applied once the submitted selection settles: the mode setters write the
// SAVED device's mode, so applying one before the bind lands would name the
// device being left (the pane disables both switches while pending for the
// same reason). Retried on main rather than waited for, since the settlement
// needs this thread. Gives up after `attempts`; the reply has already told the
// caller to confirm with dump_state.
static void VibeApplyOutputModesWhenSelectionSettles(MainPlayerController *controller,
                                                     NSNumber *bitPerfect,
                                                     NSNumber *exclusive,
                                                     NSInteger attempts) {
    if (attempts <= 0) {
        // Logged: a dropped mode looks exactly like one never asked for.
        LogWarn(@"set_output_device: gave up waiting for the selection to settle; "
                @"bit-perfect=%@ exclusive=%@ NOT applied",
                bitPerfect ?: @"-", exclusive ?: @"-");
        return;
    }
    if (controller.devicesMenuController.outputDeviceSelectionPending) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VibeApplyOutputModesWhenSelectionSettles(controller, bitPerfect, exclusive, attempts - 1);
        });
        return;
    }
    if (bitPerfect) {
        AppSettings.sharedInstance.bitPerfectOutput = bitPerfect.boolValue;
    }
    if (exclusive) {
        AppSettings.sharedInstance.exclusiveOutput = exclusive.boolValue;
    }
    [controller applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
    LogWarn(@"set_output_device: applied bit-perfect=%@ exclusive=%@ after selection settled",
            bitPerfect ?: @"-", exclusive ?: @"-");
}

// A conversion's file moves settle after the undo manager call returns, so the
// reply waits on the controller's one-shot settled hook rather than racing the
// Trash; a reply outliving the client's timeout writes one orphan response and
// cannot fire on a later menu-driven undo. A non-conversion undo settles inside
// the call and never fires the hook, so the post-call check answers it.
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
    // The hook clears itself as it fires. Still installed with no conversion
    // in flight means this undo was not a conversion's: reply now.
    if (controller.conversionUndoRedoSettledHandler
            && !controller.isConversionUndoRedoInFlight) {
        controller.conversionUndoRedoSettledHandler = nil;
        settled(YES, nil);
    }
    return nil; // response written by the settled block
}

// A theme by stable id or display name (case-insensitive); nil when it names
// nothing.
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

static NSRect VibeWindowFrameForBodyWidth(MainWindow *window, CGFloat bodyPoints) {
    CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
    NSRect frame = window.frame;
    frame.size.width = MAX(window.minSize.width, bodyPoints + panel);
    return [window frameKeptOnScreen:frame];
}

static double VibeProcessCPUSeconds(void) {
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec
            + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}

// Dispatch, the unknown-command reply and the client's per-verb wait all
// derive from this table, so an entry here is the entire app-side hookup.
NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
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
                // Removing the active theme applies the built-in Vibe theme
                // in the store; the apply effect makes that visible.
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
            // Inline JSON or a path the app can read (the container, or a
            // granted folder).
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
            // TRAP: a shell-driven launch lands behind the frontmost app (the
            // launch's cooperative activate is declined), and once the window
            // is occluded and playback paused the OS defers the whole app: its
            // timers and the channel's wake-up stall for up to ~20s. Ordered
            // front without activating, so the frontmost app keeps the
            // keyboard. No ordering helps a sleeping display or a locked
            // screen, where every window reads occluded. Occlusion settles
            // asynchronously, hence the spin.
            VibeDebugCmd(@"raise_window", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSWindow *window = controller.window;
                [window orderFrontRegardless];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
                while (!(window.occlusionState & NSWindowOcclusionStateVisible) && deadline.timeIntervalSinceNow > 0) {
                    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
                return VibeJSONString(@{@"ok": @YES,
                        @"visible": @((BOOL)((window.occlusionState & NSWindowOcclusionStateVisible) != 0)),
                        @"displayAsleep": @((BOOL)(CGDisplayIsAsleep(CGMainDisplayID()) != 0))});
            }),
            // By UID, not HAL device id, which an unplug and replug can
            // change; UID is also what AppSettings keys per-device modes by.
            // Name is the fallback, in resolveOutputDeviceForUID:name:'s
            // order, because a human can type a name but not a UID.
            //
            // The modes are only requested here (see
            // VibeApplyOutputModesWhenSelectionSettles); confirm with
            // dump_state.player.bitPerfect.
            VibeDebugCmd(@"set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2 || tokens.count > 4) {
                    return VibeErrorJSON(@"usage: set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]");
                }
                NSString *wanted = tokens[1];
                NSInteger deviceId = -1;
                AudioDevice *match = nil;
                if (![wanted.lowercaseString isEqualToString:@"system"]) {
                    NSArray<AudioDevice *> *devices = [AudioDeviceManager.sharedInstance outputDevices];
                    for (AudioDevice *device in devices) {
                        if ([device.uid isEqualToString:wanted]) {
                            match = device;
                            break;
                        }
                    }
                    if (!match) {
                        for (AudioDevice *device in devices) {
                            if ([device.name isEqualToString:wanted]) {
                                match = device;
                                break;
                            }
                        }
                    }
                    if (!match) {
                        NSMutableArray<NSString *> *known = [NSMutableArray array];
                        for (AudioDevice *device in devices) {
                            [known addObject:device.name ?: @""];
                        }
                        return VibeErrorJSON(@"no output device with UID or name '%@' (known: %@)",
                                             wanted, [known componentsJoinedByString:@", "]);
                    }
                    deviceId = match.deviceId;
                }
                [controller.devicesMenuController selectOutputDevice:deviceId];

                NSNumber *bitPerfect = nil, *exclusive = nil;
                BOOL parsed = NO;
                if (tokens.count >= 3) {
                    NSArray<NSString *> *pair = @[tokens[0], tokens[2]];
                    if (!VibeParseOnOff(pair, &parsed)) {
                        return VibeErrorJSON(@"bit-perfect argument must be on or off");
                    }
                    bitPerfect = @(parsed);
                }
                if (tokens.count == 4) {
                    NSArray<NSString *> *pair = @[tokens[0], tokens[3]];
                    if (!VibeParseOnOff(pair, &parsed)) {
                        return VibeErrorJSON(@"exclusive argument must be on or off");
                    }
                    exclusive = @(parsed);
                }
                if (bitPerfect || exclusive) {
                    VibeApplyOutputModesWhenSelectionSettles(controller, bitPerfect, exclusive, 600);
                }
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"deviceId": @(deviceId),
                    @"uid": match.uid ?: @"",
                    @"name": match.name ?: @"System Output",
                    @"selectionPending": @(controller.devicesMenuController.outputDeviceSelectionPending),
                    @"modesRequested": @(bitPerfect != nil || exclusive != nil),
                });
            }),
            VibeDebugCmd(@"set_saved_output_device <uid> <name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count != 3) {
                    return VibeErrorJSON(@"usage: set_saved_output_device <uid> <name>");
                }
                // Next-launch input only; exercise missing-device restoration
                // without changing the live binding or editing container prefs.
                AppSettings.sharedInstance.audioOutputDeviceUID = tokens[1];
                AppSettings.sharedInstance.audioOutputDeviceName = tokens[2];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"set_bit_perfect <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The pane's toggle minus its eligibility gate: forcing the
                // mode on over an ineligible device, the report reads off,
                // which is what a test of that gate wants. Like the pane it
                // writes the SAVED device's mode, and System Output, with no
                // UID to remember it under, answers off.
                BOOL on;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_bit_perfect <on|off>");
                }
                if (controller.devicesMenuController.outputDeviceSelectionPending) {
                    return VibeErrorJSON(@"output device selection is still pending");
                }
                AppSettings.sharedInstance.bitPerfectOutput = on;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"bitPerfectOutput": @(AppSettings.sharedInstance.bitPerfectOutput),
                });
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
            VibeDebugCmd(@"set_window_width <body-points> [height-points] [seconds]", 15, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double bodyPoints = 0, height = controller.window.frame.size.height, seconds = 0;
                if (tokens.count < 2 || tokens.count > 4 || !VibeParseDouble(tokens[1], &bodyPoints)
                        || (tokens.count > 2 && !VibeParseDouble(tokens[2], &height))
                        || (tokens.count > 3 && !VibeParseDouble(tokens[3], &seconds))
                        || !isfinite(bodyPoints) || bodyPoints <= 0 || bodyPoints > 10000
                        || !isfinite(height) || height <= 0 || height > 10000
                        || !isfinite(seconds) || seconds < 0 || seconds > 10) {
                    return VibeErrorJSON(@"usage: set_window_width <body-points> [height-points] [seconds 0..10]");
                }
                MainWindow *window = (MainWindow *)controller.window;
                CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
                NSRect initial = window.frame;
                NSRect frame = VibeWindowFrameForBodyWidth(window, bodyPoints);
                frame.size.height = MAX(window.minSize.height, height);
                frame.origin.y = NSMaxY(initial) - frame.size.height;
                NSString *(^reply)(void) = ^{
                    return VibeJSONString(@{
                        @"ok": @YES, @"frame": NSStringFromRect(window.frame),
                        @"bodyWidth": @(window.frame.size.width - panel),
                    });
                };
                if (seconds == 0) {
                    [window setFrame:frame display:YES];
                    return reply();
                }
                // Frame changes at 60 Hz: layout and rendering, not an NSEvent
                // tracking loop.
                NSUInteger steps = (NSUInteger)ceil(seconds * 60);
                __block NSUInteger step = 0;
                NSTimer *timer = [NSTimer timerWithTimeInterval:seconds / steps repeats:YES block:^(NSTimer *timer) {
                    CGFloat t = (CGFloat)++step / steps;
                    NSRect next = NSMakeRect(initial.origin.x + (frame.origin.x - initial.origin.x) * t,
                                             initial.origin.y + (frame.origin.y - initial.origin.y) * t,
                                             initial.size.width + (frame.size.width - initial.size.width) * t,
                                             initial.size.height + (frame.size.height - initial.size.height) * t);
                    VibeSignpostBegin(window_resize);
                    [window setFrame:next display:YES];
                    VibeSignpostEnd(window_resize);
                    if (step == steps) {
                        [timer invalidate];
                        VibeWriteDebugResponse(commandId, reply());
                    }
                }];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
                return nil;
            }),
            VibeDebugCmd(@"measure_resize <min-width> <max-width> <frames>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                static BOOL measuring = NO;
                double minWidth = 0, maxWidth = 0;
                NSUInteger frames = 0;
                if (tokens.count != 4 || !VibeParseDouble(tokens[1], &minWidth)
                        || !VibeParseDouble(tokens[2], &maxWidth)
                        || !VibeParseNonnegativeInteger(tokens[3], &frames)
                        || minWidth <= 0 || maxWidth <= minWidth || frames < 30 || frames > 600) {
                    return VibeErrorJSON(@"usage: measure_resize <min-width> <max-width> <frames 30-600>");
                }
                if (measuring) return VibeErrorJSON(@"a resize measurement is already running");
                measuring = YES;
                MainWindow *window = (MainWindow *)controller.window;
                NSRect originalFrame = window.frame;
                [window setFrame:VibeWindowFrameForBodyWidth(window, minWidth) display:YES];
                // Warm the first layout, then measure at display cadence with
                // no channel round trip per frame.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:frames];
                    double cpuStart = VibeProcessCPUSeconds();
                    CFTimeInterval start = CACurrentMediaTime();
                    __block NSUInteger index = 0;
                    VibeWorkTallyBegin("resize");
                    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
                        double phase = (double)index / (frames - 1);
                        double width = minWidth + (maxWidth - minWidth) * (1 - fabs(2 * phase - 1));
                        CFTimeInterval frameStart = CACurrentMediaTime();
                        [window setFrame:VibeWindowFrameForBodyWidth(window, width) display:YES];
                        [durations addObject:@((CACurrentMediaTime() - frameStart) * 1000)];
                        if (++index < frames) return;
                        [timer invalidate];
                        // Include the final compositor commit and morph tail.
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            double cpu = VibeProcessCPUSeconds() - cpuStart;
                            double elapsed = CACurrentMediaTime() - start;
                            NSDictionary *work = VibeWorkTallyTakeWindow();
                            NSArray<NSNumber *> *sorted = [durations sortedArrayUsingSelector:@selector(compare:)];
                            double total = 0;
                            for (NSNumber *duration in durations) total += duration.doubleValue;
                            [window setFrame:originalFrame display:YES];
                            measuring = NO;
                            VibeWriteDebugResponse(commandId, VibeJSONString(@{
                                @"ok": @YES, @"frames": @(frames), @"elapsedSeconds": @(elapsed),
                                @"cpuSeconds": @(cpu), @"frameMeanMS": @(total / frames),
                                @"frameP95MS": sorted[(frames - 1) * 95 / 100], @"frameMaxMS": sorted.lastObject,
                                @"work": work,
                            }));
                        });
                    }];
                    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
                });
                return nil;
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
            // The whole Convert to FLAC path on the current track, swap and
            // disposal included. keep|delete writes Delete Original After
            // Convert, as the menu item does, and leaves it written.
            // omit-trash-url is a one-shot fault for the ambiguous successful
            // Trash result, armed only once the command will convert.
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
                // Refuse before touching the one-shot fault: clearing or arming
                // it while an earlier conversion runs would change that
                // request's undo record. Mirroring the converter's synchronous
                // refusals also keeps an unaccepted request from leaving a
                // fault for some later conversion.
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
                    // Source disposal normally consumes the fault; cancel it
                    // only if this request's is still pending after a failure.
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
