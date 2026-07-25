//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugUtil.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>
#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Debug.h"
#import "MainWindow.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"
#import "PlaylistManager.h"
#import "NSURLUtil.h"
#import "PitchControlPanel.h"
#import "GlyphButton.h"

static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
}

// Glass views' hosting layers render as opaque white in renderInContext:
// (their real content is window-server composited), painting over everything
// below them in the tree — so they must be hidden for the render, not just
// underpainted.
static void VibeCollectGlassLayers(NSView *view, NSMutableArray<CALayer *> *out) {
    if ([view isKindOfClass:[NSGlassEffectView class]]) {
        if (view.layer) {
            [out addObject:view.layer];
        }
        return;
    }
    for (NSView *subview in view.subviews) {
        VibeCollectGlassLayers(subview, out);
    }
}

static void VibeDumpWindowSnapshot(void) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) {
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.contentView) {
                window = candidate;
                break;
            }
        }
    }
    NSView *view = window.contentView;
    if (!view || NSIsEmptyRect(view.bounds)) {
        LogError(@"Debug screenshot: no window content to render");
        return;
    }
    CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0;
    size_t pixelsWide = (size_t)llround(view.bounds.size.width * scale);
    size_t pixelsHigh = (size_t)llround(view.bounds.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        return;
    }
    CGContextScaleCTM(ctx, scale, scale);
    // With the glass layers hidden below, their region renders transparent —
    // paint an appearance-matched proxy background first so dark-mode content
    // (white text/waveform at low alpha) keeps the window's real contrast
    // polarity instead of flattening onto white.
    NSAppearanceName match = [window.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL isDark = [match isEqualToString:NSAppearanceNameDarkAqua];
    CGContextSetGrayFillColor(ctx, isDark ? 0.1 : 0.95, 1.0);
    CGContextFillRect(ctx, view.bounds);
    CALayer *layer = view.layer;
    if (layer) {
        NSMutableArray<CALayer *> *glassLayers = [NSMutableArray array];
        VibeCollectGlassLayers(view, glassLayers);
        if (glassLayers.count > 0) {
            // The hides must stay uncommitted so the on-screen window never
            // flickers — which forces rendering the model tree (an uncommitted
            // change is invisible to a presentation copy). Costs mid-flight
            // animation capture, but only glass-bearing windows pay it.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            for (CALayer *glass in glassLayers) {
                glass.hidden = YES;
            }
            [layer renderInContext:ctx];
            for (CALayer *glass in glassLayers) {
                glass.hidden = NO;
            }
            [CATransaction commit];
        }
        else {
            // Presentation tree when available: captures animations mid-flight.
            CALayer *presentation = layer.presentationLayer ?: layer;
            [presentation renderInContext:ctx];
        }
    }
    else {
        // Non-layer-backed fallback: AppKit drawing path.
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [view displayRectIgnoringOpacity:view.bounds inContext:gc];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) {
        return;
    }
    NSString *path = VibeDebugScreenshotPath();
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
        LogInfo(@"Debug screenshot written to %@", path);
    }
    CGImageRelease(image);
}

void VibeInstallDebugScreenshotHook(void) {
    static int token;
    notify_register_dispatch("com.vibe.debug.screenshot", &token, dispatch_get_main_queue(), ^(int t) {
        VibeDumpWindowSnapshot();
    });
}

#pragma mark - Debug command channel

static NSString *const kVibeDebugCommandNotification = @"com.vibe.debug.command";

static NSString *VibeDebugTmpPath(NSString *name) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

// Per-command files, like the response side: one fixed command path loses a
// command when two clients write back-to-back (the second write replaces the
// first before the app reads it).
static NSString *VibeDebugCommandPath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-command-%@.json", commandId]);
}

static NSString *VibeDebugResponsePath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-response-%@.txt", commandId]);
}

#pragma mark App side: command execution

static NSString *VibePlayerStateName(AudioPlayer *player) {
    // Loading reports isPlaying (with zero position/duration), so this shows
    // "playing" during an in-flight open — same as the transport button.
    if (player.isPlaying) {
        return @"playing";
    }
    return player.isPaused ? @"paused" : @"stopped";
}

static NSDictionary *VibeStateDictionary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    PlaylistManager *playlist = controller.playlistManager;
    AudioTrack *track = playlist.currentTrack;

    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (AudioTrack *t in playlist.playlist) {
        if (files.count == 100) {
            [files addObject:[NSString stringWithFormat:@"… %lu more", (unsigned long)(playlist.count - 100)]];
            break;
        }
        [files addObject:t.url.lastPathComponent ?: @""];
    }

    return @{
        @"player": @{
            @"state": VibePlayerStateName(player),
            @"position": @(player.position),
            @"duration": @(player.duration),
            @"pitch": @(player.pitch),
            @"maxPitch": @(player.maxPitch),
            @"playbackRate": @(1.0 + player.pitch / 100.0),
            @"lowKill": @(player.fx.lowKillEnabled),
            @"lowKillBoost": @(player.fx.lowKillBoostActive),
            @"reverbSend": @(player.fx.reverbSendEnabled),
            @"delaySend": @(player.fx.delaySendEnabled),
            @"shortDelaySend": @(player.fx.shortDelaySendEnabled),
            @"delayTapBPM": @(player.fx.delayTapBPM),
            @"numChannels": @(player.numChannels),
            @"outputDeviceId": @(player.currentlyActiveAudioDeviceId),
        },
        @"currentTrack": track ? @{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
        } : (id)NSNull.null,
        @"playlist": @{
            @"count": @(playlist.count),
            @"currentIndex": @(playlist.currentIndex),
            @"files": files,
        },
        @"ui": @{
            @"title": controller.titleTextField.stringValue ?: @"",
            @"artist": controller.artistTextField.stringValue ?: @"",
            @"currentTime": controller.currentTimeTextField.stringValue ?: @"",
            @"totalTime": controller.totalTimeTextField.stringValue ?: @"",
            @"fileMetadata": controller.fileMetadataTextField.stringValue ?: @"",
            @"timeLabelsHidden": @(controller.currentTimeTextField.isHidden),
            @"playButtonEnabled": @(controller.playButton.isEnabled),
            @"nextButtonEnabled": @(controller.nextButton.isEnabled),
            @"pitchFader": @(controller.pitchPanel.pitch),
        },
        @"window": @{
            @"frame": NSStringFromRect(window.frame),
            @"playlistShown": @(window.isPlaylistShown),
            @"pitchPanelShown": @(window.isPitchPanelShown),
            @"keyWindow": @(window.isKeyWindow),
        },
        @"settings": @{
            @"pitchRange": @(Settings.pitchRange),
            @"playlistShown": @(Settings.isPlaylistShown),
            @"pitchPanelShown": @(Settings.isPitchPanelShown),
            @"waveformStyle": Settings.waveformStyle ?: @"",
            @"outputDeviceName": Settings.audioOutputDeviceName ?: @"",
        },
    };
}

// Every debug command replies with exactly one JSON object; errors are
// {"error": "..."} (the client maps them to exit code 2).
static NSString *VibeJSONString(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return json ?: @"{\"error\": \"response not JSON-serializable\"}";
}

static NSString *VibeErrorJSON(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *VibeErrorJSON(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return VibeJSONString(@{@"error": message});
}

static NSDictionary *VibeViewDictionary(NSView *view) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"class"] = view.className;
    node[@"address"] = [NSString stringWithFormat:@"%p", view];
    if (view.identifier.length) {
        node[@"id"] = view.identifier;
    }
    node[@"frame"] = NSStringFromRect(view.frame);
    if (view.isHidden) {
        node[@"hidden"] = @YES;
    }
    if (view.alphaValue < 1.0) {
        node[@"alpha"] = @(view.alphaValue);
    }
    if (view.autoresizingMask != NSViewNotSizable) {
        node[@"mask"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)view.autoresizingMask];
    }
    if (view.subviews.count) {
        NSMutableArray *subviews = [NSMutableArray array];
        for (NSView *subview in view.subviews) {
            [subviews addObject:VibeViewDictionary(subview)];
        }
        node[@"subviews"] = subviews;
    }
    return node;
}

static NSString *VibeViewTreeDump(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) {
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"class"] = window.className;
        node[@"address"] = [NSString stringWithFormat:@"%p", window];
        node[@"title"] = window.title ?: @"";
        node[@"frame"] = NSStringFromRect(window.frame);
        node[@"visible"] = @(window.isVisible);
        node[@"key"] = @(window.isKeyWindow);
        if (window.contentView) {
            node[@"contentView"] = VibeViewDictionary(window.contentView);
        }
        [windows addObject:node];
    }
    return VibeJSONString(@{@"windows": windows});
}

static NSArray *VibeMenuArray(NSMenu *menu) {
    // Delegate-built menus (Output devices, Open Recent, waveform styles)
    // only populate when displayed; ask the delegate directly the way display
    // would — [menu update] alone does not call menuNeedsUpdate:.
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
        [menu.delegate menuNeedsUpdate:menu];
    }
    // Runs validateMenuItem exactly like opening the menu would, so
    // enabled/checkmark below are live, not stale defaults.
    [menu update];
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) {
            [items addObject:@{@"separator": @YES}];
            continue;
        }
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"title"] = item.title;
        if (item.identifier.length) {
            node[@"id"] = item.identifier;
        }
        if (item.keyEquivalent.length) {
            node[@"key"] = item.keyEquivalent;
            if (item.keyEquivalentModifierMask) {
                node[@"mods"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)item.keyEquivalentModifierMask];
            }
        }
        if (item.action) {
            node[@"action"] = NSStringFromSelector(item.action);
        }
        node[@"enabled"] = @(item.isEnabled);
        if (item.state != NSControlStateValueOff) {
            node[@"state"] = @(item.state);
        }
        if (item.submenu) {
            node[@"items"] = VibeMenuArray(item.submenu);
        }
        [items addObject:node];
    }
    return items;
}

static NSMenuItem *VibeFindMenuItem(NSMenu *menu, NSString *name) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:name] || [item.title isEqualToString:name]) {
            return item;
        }
        if (item.submenu) {
            NSMenuItem *found = VibeFindMenuItem(item.submenu, name);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

static NSString *VibeClickMenuItem(NSString *name) {
    NSMenuItem *item = VibeFindMenuItem(NSApp.mainMenu, name);
    if (!item) {
        return VibeErrorJSON(@"no menu item with identifier or title '%@' (run `menu` to list)", name);
    }
    [item.menu update]; // same validation pass opening the menu would run
    if (!item.isEnabled) {
        return VibeErrorJSON(@"menu item '%@' is disabled", item.title);
    }
    if (!item.action) {
        return VibeErrorJSON(@"menu item '%@' has no action", item.title);
    }
    if (![NSApp sendAction:item.action to:item.target from:item]) {
        return VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(item.action));
    }
    return VibeJSONString(@{
        @"ok": @YES,
        @"clicked": item.title,
        @"action": NSStringFromSelector(item.action),
    });
}

// Compact result for action commands: enough to assert on without a second
// `state` round-trip. Transport actions kick off async engine work, so state
// here can be a beat behind (it's read synchronously after the call).
static NSString *VibeActionSummary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    return VibeJSONString(@{
        @"ok": @YES,
        @"state": VibePlayerStateName(player),
        @"index": @(controller.playlistManager.currentIndex),
        @"count": @(controller.playlistManager.count),
        @"position": @(player.position),
        @"pitch": @(player.pitch),
        @"lowKill": @(player.fx.lowKillEnabled),
        @"reverbSend": @(player.fx.reverbSendEnabled),
        @"delaySend": @(player.fx.delaySendEnabled),
        @"shortDelaySend": @(player.fx.shortDelaySendEnabled),
        @"playlistShown": @(window.isPlaylistShown),
        @"pitchPanelShown": @(window.isPitchPanelShown),
    });
}

// Writes the per-command response file the client polls for. Used both by the
// synchronous path (VibeHandleDebugCommandFile) and by commands that finish
// asynchronously and call this from their own completion block.
static void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
}

// tokens[0] is the verb; the rest are its arguments — one token per CLI argv
// entry, transported verbatim (never re-tokenized). Rejoined with single
// spaces as a convenience so an unquoted multi-word title still works; a
// properly QUOTED argument arrives as one token and passes through exactly,
// consecutive spaces and all.
static NSString *VibeRestArgument(NSArray<NSString *> *tokens) {
    return [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
            componentsJoinedByString:@" "];
}

// Path argument: the rest of the tokens with a leading ~ expanded.
static NSString *VibePathArgument(NSArray<NSString *> *tokens) {
    return VibeRestArgument(tokens).stringByExpandingTildeInPath;
}

// Shared validation for verbs taking one existing-file argument — keeps
// file_cache and file_clear_cache's argument contracts identical. Returns the
// path, or nil with *errorJSON set to the reply to send.
static NSString *VibeExistingFileArgument(NSArray<NSString *> *tokens, NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <file>", verb);
        return nil;
    }
    NSString *path = VibePathArgument(tokens);
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
        *errorJSON = VibeErrorJSON(@"%@ expects an existing file: '%@'", verb, path);
        return nil;
    }
    return path;
}

#pragma mark Command table

// One handler per verb; tokens[0] is the verb itself. Returning nil means the
// command completes asynchronously and writes its own response later via
// VibeWriteDebugResponse(commandId, ...) from a completion block.
typedef NSString * _Nullable (^VibeDebugCommandHandler)(NSArray<NSString *> *tokens,
                                                        NSString *commandId,
                                                        MainPlayerController *controller);

// usage's first word is the verb. clientTimeout is how long the CLI client
// waits for this verb's response, in seconds (0 = the default; see
// VibeDebugCommandClientMain).
static NSDictionary *VibeCmd(NSString *usage, NSTimeInterval clientTimeout, VibeDebugCommandHandler handler) {
    return @{@"usage": usage, @"clientTimeout": @(clientTimeout), @"handler": [handler copy]};
}

// Transport/toggle verbs: invoke the controller action, reply with the compact
// action summary.
static NSDictionary *VibeActionCmd(NSString *usage, void (^action)(MainPlayerController *controller)) {
    return VibeCmd(usage, 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
        action(controller);
        return VibeActionSummary(controller);
    });
}

// THE command set — dispatch, the unknown-command usage reply, and the
// client's per-verb wait all derive from this table, so adding an entry here
// is the entire app-side hookup (usage docs live in the vibe-debug skill).
static NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeCmd(@"dump_state", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(VibeStateDictionary(controller));
            }),
            VibeCmd(@"dump_now_playing", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The state we publish to the system Now Playing UI (Control
                // Center, media keys). Cross-checks the NowPlayingController
                // wiring without a private-framework reader.
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
            VibeCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeViewTreeDump();
            }),
            VibeCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeJSONString(@{@"menu": VibeMenuArray(NSApp.mainMenu)});
            }),
            VibeCmd(@"dump_screenshot [-]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // "-" is client-side: the CLI streams the PNG bytes to stdout.
                VibeDumpWindowSnapshot();
                return VibeJSONString(@{@"path": VibeDebugScreenshotPath()});
            }),
            VibeCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
                }
                // Rest of the tokens, so exact titles with spaces work too.
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
            VibeCmd(@"set_pitch <percent>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_pitch <percent>");
                }
                // Through the panel first so the fader clamps to its range
                // exactly like a drag, then the player takes the clamped value.
                controller.pitchPanel.pitch = tokens[1].floatValue;
                controller.audioPlayer.pitch = controller.pitchPanel.pitch;
                [controller debugRefreshUI];
                return VibeActionSummary(controller);
            }),
            VibeCmd(@"seek <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: seek <seconds>");
                }
                [controller.audioPlayer seekToPosition:tokens[1].doubleValue];
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
                // Same expand/filter/play pipeline as a Finder open or a file
                // drop: a directory is walked and unsupported files dropped.
                // Async (a large folder walk shouldn't stall the channel) —
                // the reply acks the request; poll `dump_state` for the
                // resulting playlist. Sandbox: an arbitrary path the app
                // hasn't been granted may be denied at read time (same caveat
                // as command-line args); `open -a "$APP"` grants access.
                [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                                    completion:^(NSArray<NSURL *> *expanded) {
                    if (expanded.count > 0) {
                        [controller play:expanded];
                    }
                }];
                return VibeJSONString(@{@"ok": @YES, @"opening": path});
            }),
            // Normally never reached from the CLI: the client executes
            // scan_bpm locally (see VibeDebugCommandClientMain), so this
            // entry exists for the usage listing and for callers that post
            // the command file directly. Same core function either way.
            VibeCmd(@"scan_bpm <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // Full-file decode — keep it off the main thread.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    VibeWriteDebugResponse(commandId, VibeDebugBPMScanJSON(path));
                });
                return nil; // response written by the block above
            }),
            VibeCmd(@"file_cache <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // Decode + persist this file's waveform without disturbing the
                // current load, then reply with its detected BPM once the entry
                // is on disk. A cold decode of a long file runs well past the
                // default client wait — hence this verb's 60s clientTimeout.
                [controller.waveformCache cacheWaveformForURL:[NSURL fileURLWithPath:path]
                                                   completion:^(BOOL ok, BOOL wasCached, float bpm) {
                    NSString *reply = ok
                            ? VibeJSONString(@{@"ok": @YES, @"path": path, @"wasCached": @(wasCached), @"bpm": @(bpm)})
                            : VibeErrorJSON(@"waveform decode failed for '%@'", path);
                    VibeWriteDebugResponse(commandId, reply);
                }];
                return nil; // response written by the completion above
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
            // clientTimeout 20 > the 15s app-side dispatch_group_wait: the
            // waveform clear queues behind any in-flight waveform load, and a
            // flat 5s client wait could give up on a clear that succeeds.
            VibeCmd(@"clear_caches", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Blocks the main thread until both PINCache stores are empty —
                // acceptable for a debug-only command; the clears are file
                // deletes at utility QoS.
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
                    @"cleared": @[@"Audio Track Metadata v4", @"audio_waveform_cache_v4"],
                });
            }),
        ];
    });
    return table;
}

static NSString *VibeVerbFromUsage(NSString *usage) {
    NSRange space = [usage rangeOfString:@" "];
    return space.location == NSNotFound ? usage : [usage substringToIndex:space.location];
}

static NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    for (NSDictionary *spec in VibeDebugCommandTable()) {
        if ([VibeVerbFromUsage(spec[@"usage"]) isEqualToString:verb]) {
            return spec;
        }
    }
    return nil;
}

// Returns the JSON response to write, or nil if the command completes
// asynchronously and writes its own response via VibeWriteDebugResponse (e.g.
// file_cache, which runs a full waveform decode off the main thread).
static NSString *VibeExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    MainPlayerController *controller = [appDelegate isKindOfClass:AppDelegate.class]
            ? appDelegate.mainPlayerController : nil;
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *spec = VibeCommandSpecForVerb(verb);
    if (!spec) {
        NSMutableArray<NSString *> *usages = [NSMutableArray array];
        for (NSDictionary *entry in VibeDebugCommandTable()) {
            [usages addObject:entry[@"usage"]];
        }
        return VibeErrorJSON(@"unknown command '%@'. Commands: %@",
                verb, [usages componentsJoinedByString:@", "]);
    }
    VibeDebugCommandHandler handler = spec[@"handler"];
    return handler(tokens, commandId, controller);
}

static void VibeHandleOneDebugCommandFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    // Malformed payloads still get an {"error": ...} reply whenever the id is
    // recoverable — a silent drop leaves the client polling out its window and
    // blaming a missing debug build.
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *commandId = [payload isKindOfClass:NSDictionary.class] ? payload[@"id"] : nil;
    if (![commandId isKindOfClass:NSString.class] || commandId.length == 0) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<not UTF-8>";
        if (raw.length > 256) {
            raw = [[raw substringToIndex:256] stringByAppendingString:@"…"];
        }
        LogError(@"Debug command payload has no usable id, dropping: %@", raw);
        return;
    }
    NSArray *args = payload[@"args"];
    NSString *malformed = nil;
    if (![args isKindOfClass:NSArray.class] || args.count == 0) {
        malformed = @"payload 'args' must be a non-empty JSON array";
    }
    else {
        for (id token in args) {
            if (![token isKindOfClass:NSString.class]) {
                malformed = @"payload 'args' must contain only strings";
                break;
            }
        }
    }
    if (malformed) {
        VibeWriteDebugResponse(commandId, VibeErrorJSON(@"%@", malformed));
        return;
    }
    NSString *response = VibeExecuteDebugCommand(args, commandId);
    // A nil response means the command completes asynchronously and writes its
    // own response via VibeWriteDebugResponse when done (e.g. file_cache).
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
    LogInfo(@"Debug command dispatched: %@", [args componentsJoinedByString:@" "]);
}

// notify_post coalesces back-to-back posts into one delivery, so a single
// wake-up must drain every pending command file. Each reply pairs with its
// command via the id.
static void VibeHandleDebugCommandFiles(void) {
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:@"vibe-command-"] && [name hasSuffix:@".json"]) {
            VibeHandleOneDebugCommandFile([tmpDir stringByAppendingPathComponent:name]);
        }
    }
}

void VibeInstallDebugCommandHook(void) {
    // Sweep responses orphaned by earlier runs: an async verb that outlives
    // its client's poll window writes a response no one ever deletes (the
    // client cleans up only its command file), so vibe-response-*.txt litter
    // accumulates in the container tmp until the OS purges it. Anything
    // present before this hook is live belongs to a dead conversation.
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in names) {
        if ([name hasPrefix:@"vibe-response-"] && [name hasSuffix:@".txt"]) {
            [NSFileManager.defaultManager removeItemAtPath:[tmpDir stringByAppendingPathComponent:name]
                                                     error:nil];
        }
    }
    static int token;
    notify_register_dispatch(kVibeDebugCommandNotification.UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        VibeHandleDebugCommandFiles();
    });
}

#pragma mark Client side

int VibeDebugCommandClientMain(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [args addObject:@(argv[i])];
        }
        if (args.count == 0) {
            fprintf(stderr, "usage: Vibe --debug-cmd <command> [args...]\n");
            return 64;
        }
        // scan_bpm runs IN THIS PROCESS — a pure decode+analyze with no app
        // state — so the client skips the channel round-trip entirely: it
        // works with no app running and never disturbs a running instance.
        // `scan_bpm - < file` streams the audio via stdin: this process owns
        // the app container and stages the bytes in its own tmp — a shell cp
        // into ~/Library/Containers/<id>/ trips macOS 14+ app-data
        // protection, while inherited fds cross the sandbox freely. The
        // staged file carries no extension: CoreAudio identifies the format
        // by content (verified for WAV/FLAC/MP4/ADTS).
        if ([args.firstObject isEqualToString:@"scan_bpm"]) {
            NSString *json = nil;
            if (args.count == 2 && [args[1] isEqualToString:@"-"]) {
                NSData *audio = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
                if (audio.length == 0) {
                    fprintf(stderr, "vibe: empty stdin — usage: Vibe --debug-cmd scan_bpm - < file\n");
                    return 64;
                }
                NSString *staged = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"bpm-scan-%@", NSUUID.UUID.UUIDString]];
                if (![audio writeToFile:staged atomically:YES]) {
                    fprintf(stderr, "vibe: cannot write %s\n", staged.fileSystemRepresentation);
                    return 1;
                }
                json = VibeDebugBPMScanJSON(staged);
                [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
            }
            else if (args.count == 2) {
                json = VibeDebugBPMScanJSON(args[1]);
            }
            else {
                fprintf(stderr, "usage: Vibe --debug-cmd scan_bpm <file | ->\n");
                return 64;
            }
            printf("%s\n", json.UTF8String);
            NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
                    [json dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data
                                                                  options:0
                                                                    error:nil];
            return reply[@"error"] != nil ? 2 : 0;
        }
        // In-process for the same container-ownership reason (a shell rm -rf
        // into the container prompts). Only for when no app is running —
        // deleting under a live app races its open caches (clear-caches.sh
        // guards with pgrep and uses the channel's clear_caches instead).
        if ([args.firstObject isEqualToString:@"clear_disk_caches"]) {
            NSString *caches = NSSearchPathForDirectoriesInDomains(
                    NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSFileManager *fm = NSFileManager.defaultManager;
            NSMutableArray<NSString *> *cleared = [NSMutableArray array];
            for (NSString *name in [fm contentsOfDirectoryAtPath:caches error:nil]) {
                if ([name hasPrefix:@"com.pinterest.PINDiskCache."]
                        && [fm removeItemAtPath:[caches stringByAppendingPathComponent:name] error:nil]) {
                    [cleared addObject:name];
                }
            }
            printf("%s\n", VibeJSONString(@{@"ok": @YES, @"cleared": cleared}).UTF8String);
            return 0;
        }
        // In-process: shell `defaults write` into the container prompts; this
        // process writes its own domain. Persists for the next launch — with
        // the app running use click_menu view_appearance_* instead. "system"
        // writes the "" follow-OS sentinel (like the View menu) rather than
        // deleting the key, whose registered default is dark.
        if ([args.firstObject isEqualToString:@"set_appearance"]) {
            NSDictionary<NSString *, NSString *> *values = @{
                @"light": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT,
                @"dark": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
                @"system": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
            };
            NSString *value = args.count == 2 ? values[args[1]] : nil;
            if (!value) {
                fprintf(stderr, "usage: Vibe --debug-cmd set_appearance <light|dark|system>\n");
                return 64;
            }
            Settings.windowAppearanceStyle = value;
            // Short-lived process: force the cfprefsd flush before exit.
            [NSUserDefaults.standardUserDefaults synchronize];
            printf("%s\n", VibeJSONString(@{@"ok": @YES, @"windowAppearance": args[1]}).UTF8String);
            return 0;
        }
        NSString *commandId = NSUUID.UUID.UUIDString;
        // Args ride a JSON array, one element per argv entry — never joined
        // and re-tokenized — so a quoted path with any whitespace (including
        // consecutive spaces) reaches the handler byte-exact.
        NSDictionary *payload = @{
            @"id": commandId,
            @"args": args,
        };
        // Same bundle ID + sandbox entitlements as the app, so NSTemporaryDirectory()
        // resolves to the same container tmp the app-side handler reads.
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *commandPath = VibeDebugCommandPath(commandId);
        if (![data writeToFile:commandPath atomically:YES]) {
            fprintf(stderr, "vibe: cannot write %s\n", commandPath.fileSystemRepresentation);
            return 1;
        }
        notify_post(kVibeDebugCommandNotification.UTF8String);

        NSString *responsePath = VibeDebugResponsePath(commandId);
        NSFileManager *fileManager = NSFileManager.defaultManager;
        // Per-verb wait from the same table the app dispatches with — slow
        // verbs (file_cache's full decode, clear_caches' blocking clear)
        // declare their own window there; everything else gets 5s.
        NSTimeInterval timeout = [VibeCommandSpecForVerb(args.firstObject)[@"clientTimeout"] doubleValue];
        if (timeout <= 0) {
            timeout = 5;
        }
        int maxPolls = (int)(timeout / 0.05);
        for (int i = 0; i < maxPolls; i++) {
            usleep(50 * 1000);
            if ([fileManager fileExistsAtPath:responsePath]) {
                NSString *response = [NSString stringWithContentsOfFile:responsePath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:nil];
                [fileManager removeItemAtPath:responsePath error:nil];
                // Replies are always a single JSON object; {"error": ...}
                // means the command failed.
                NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
                        [response dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data
                                                                      options:0
                                                                        error:nil];
                BOOL failed = ![reply isKindOfClass:NSDictionary.class] || reply[@"error"] != nil;
                // dump_screenshot -: stream the PNG over stdout (JSON reply
                // moves to stderr). Only this process may read the PNG — it
                // lives in the app container, and another process reading it
                // trips macOS 14+ app-data protection; the inherited stdout
                // fd crosses the sandbox, and the caller opens its own
                // redirect target.
                if (!failed && [args.firstObject isEqualToString:@"dump_screenshot"]
                            && [args containsObject:@"-"]) {
                    NSString *pngPath = [reply[@"path"] isKindOfClass:NSString.class] ? reply[@"path"] : nil;
                    NSData *png = pngPath ? [NSData dataWithContentsOfFile:pngPath] : nil;
                    if (png.length == 0) {
                        fprintf(stderr, "vibe: no screenshot at %s\n",
                                pngPath.fileSystemRepresentation ?: "(no path in reply)");
                        return 2;
                    }
                    fwrite(png.bytes, 1, png.length, stdout);
                    fprintf(stderr, "%s\n", response.UTF8String);
                    return 0;
                }
                if (response.length) {
                    printf("%s\n", response.UTF8String);
                }
                return failed ? 2 : 0;
            }
        }
        [fileManager removeItemAtPath:commandPath error:nil];
        fprintf(stderr, "vibe: no response after %.0fs — is a debug build of Vibe running?\n", timeout);
        return 1;
    }
}

#endif
