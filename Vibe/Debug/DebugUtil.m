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
#import "DebugShared.h"
#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Debug.h"
#import "MainPlayerController+Transport.h"
#import "TrackDisplayController.h"
#import "MainWindow.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioLoadTiming.h"
#import "MusicalKey.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "PlaylistController.h"
#import "PlaylistDropZoneView.h"
#import "MainPlayerContentView.h"
#import "NSURLUtil.h"
#import "AppStats.h"
#import "PitchControlPanel.h"
#import "SymbolButton.h"

// The notifyutil hook's fixed output path. dump_screenshot writes a
// per-command file instead, through VibeDebugScreenshotPathForCommand, so that
// two clients snapshotting back to back cannot hand one client the other's
// pixels.
static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
}

// A glass view's hosting layer renders as opaque white in renderInContext:,
// because its real content is composited by the window server, and it paints
// over everything below it in the tree. It must therefore be hidden for the
// render, not merely underpainted.
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

static void VibeDumpWindowSnapshot(NSString *path) {
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
    // With the glass layers hidden below, their region renders transparent, so
    // paint an appearance-matched proxy background first. Dark-mode content —
    // white text and waveform at low alpha — then keeps the window's real
    // contrast polarity rather than flattening onto white.
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
            // The hides must stay uncommitted, so that the on-screen window
            // never flickers. That forces a render of the model tree, since an
            // uncommitted change is invisible to a presentation copy. It costs
            // the mid-flight animation capture, but only glass-bearing windows
            // pay for it.
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
            // The presentation tree where available, which captures animations
            // mid-flight.
            CALayer *presentation = layer.presentationLayer ?: layer;
            [presentation renderInContext:ctx];
        }
    }
    else {
        // The non-layer-backed fallback: AppKit's drawing path.
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
        VibeDumpWindowSnapshot(VibeDebugScreenshotPath());
    });
}

#pragma mark - Debug command channel

// The transport's notification name, per-command file paths and JSON reply
// serialization live in DebugShared.m, shared with the CLI client in
// DebugClient.m.

#pragma mark App side: command execution

static NSString *VibePlayerStateName(AudioPlayer *player) {
    // Loading reports isPlaying, with a zero position and duration, so this
    // shows "playing" during an in-flight open, as the transport button does.
    if (player.isPlaying) {
        return @"playing";
    }
    return player.isPaused ? @"paused" : @"stopped";
}

static NSDictionary *VibeStateDictionary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    PlaylistController *playlist = controller.playlistController;
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
            @"gaplessArmed": @(player.isGaplessArmed),
            @"outputDeviceId": @(player.currentlyActiveAudioDeviceId),
            @"silent": @([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]),
            @"noAudioHw": @([NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"]),
        },
        @"currentTrack": track ? @{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            // The resolved key (tag over analysis); empty strings when unknown.
            @"key": VibeMusicalKeyMusicalName(track.key),
            @"camelot": VibeMusicalKeyCamelotName(track.key),
        } : (id)NSNull.null,
        @"playlist": @{
            @"count": @(playlist.count),
            @"currentIndex": @(playlist.currentIndex),
            @"files": files,
        },
        @"ui": @{
            @"title": controller.trackDisplay.titleTextField.stringValue ?: @"",
            @"artist": controller.trackDisplay.artistTextField.stringValue ?: @"",
            @"currentTime": controller.trackDisplay.currentTimeTextField.stringValue ?: @"",
            @"totalTime": controller.trackDisplay.totalTimeTextField.stringValue ?: @"",
            @"fileMetadata": controller.trackDisplay.fileMetadataTextField.stringValue ?: @"",
            @"timeLabelsHidden": @(controller.trackDisplay.currentTimeTextField.isHidden),
            @"playButtonEnabled": @(controller.playButton.isEnabled),
            @"nextButtonEnabled": @(controller.nextButton.isEnabled),
            @"pitchFader": @(controller.pitchPanel.pitch),
            @"converting": @(controller.fileConverter.isConverting),
            @"convertSweep": @(controller.trackDisplay.convertSweepFraction),
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
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
            @"deleteOriginalAfterConvert": @(Settings.deleteOriginalAfterConvert),
            @"analyzeBPM": @(Settings.analyzeBPM),
            @"analyzeKey": @(Settings.analyzeKey),
            @"keyNotation": Settings.keyNotation ?: @"",
            @"keyColors": @(Settings.keyColorsEnabled),
        },
    };
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
    // Delegate-built menus — Output devices, Open Recent, waveform styles —
    // populate only when displayed, so ask the delegate directly, the way
    // display would. [menu update] alone does not call menuNeedsUpdate:.
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
        [menu.delegate menuNeedsUpdate:menu];
    }
    // Runs validateMenuItem exactly as opening the menu would, so that the
    // enabled state and checkmark below are live rather than stale defaults.
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

// A compact result for the action commands: enough to assert on without a
// second `state` round-trip. Transport actions kick off async engine work, so
// the state here can be a beat behind, since it is read synchronously after
// the call.
static NSString *VibeActionSummary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    return VibeJSONString(@{
        @"ok": @YES,
        @"state": VibePlayerStateName(player),
        @"index": @(controller.playlistController.currentIndex),
        @"count": @(controller.playlistController.count),
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

// Writes the per-command response file the client polls for. Both the
// synchronous path, VibeHandleDebugCommandFile, and commands that finish
// asynchronously and call this from their own completion block use it.
static void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
}

// tokens[0] is the verb and the rest are its arguments: one token per CLI argv
// entry, transported verbatim and never re-tokenized. They are rejoined with
// single spaces as a convenience, so that an unquoted multi-word title still
// works. A properly quoted argument arrives as one token and passes through
// exactly, consecutive spaces and all.
static NSString *VibeRestArgument(NSArray<NSString *> *tokens) {
    return [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
            componentsJoinedByString:@" "];
}

// A path argument: the rest of the tokens, with a leading ~ expanded.
static NSString *VibePathArgument(NSArray<NSString *> *tokens) {
    return VibeRestArgument(tokens).stringByExpandingTildeInPath;
}

// Shared validation for the verbs that take one existing-file argument, which
// keeps file_cache's and file_clear_cache's argument contracts identical. It
// returns the path, or nil with *errorJSON set to the reply to send.
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

#pragma mark Input injection

// Synthesized NSEvents posted into the app's own event queue, through
// [NSApp postEvent:atStart:NO]. Unlike --debug-cmd's direct action calls,
// these exercise the real event dispatch path, local monitors such as
// TransportKeyMonitor and view mouse handling included, and unlike CGEvent
// injection through input.swift they need no Accessibility permission and no
// frontmost window.
//
// They have two structural limits against real window-server events. Tracking
// areas and hover effects do not fire, because the window server drives those.
// And the posted events are processed after the reply is written, so poll
// dump_state to observe the result.
//
// Mouse coordinates are main-window points with a top-left origin, the same
// frame of reference as dump_screenshot, which is the retina pixel divided by
// two. NSEvent wants bottom-left window coordinates, converted here.

static NSTimeInterval VibeEventTimestamp(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static NSDictionary<NSString *, NSNumber *> *VibeKeyCodeMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The ANSI virtual key codes: HIToolbox Events.h values, stated inline
        // so that Carbon stays unimported.
        map = @{
            @"a": @0,  @"s": @1,  @"d": @2,  @"f": @3,  @"h": @4,  @"g": @5,
            @"z": @6,  @"x": @7,  @"c": @8,  @"v": @9,  @"b": @11, @"q": @12,
            @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17,
            @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"6": @22, @"5": @23,
            @"9": @25, @"7": @26, @"8": @28, @"0": @29,
            @"o": @31, @"u": @32, @"i": @34, @"p": @35, @"l": @37, @"j": @38,
            @"k": @40, @"n": @45, @"m": @46,
            @"return": @36, @"tab": @48, @"space": @49, @"delete": @51, @"esc": @53,
            @"left": @123, @"right": @124, @"down": @125, @"up": @126,
        };
    });
    return map;
}

static NSString *VibeKeyCharacters(NSString *name) {
    static NSDictionary<NSString *, NSString *> *special;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        special = @{
            @"return": @"\r", @"tab": @"\t", @"space": @" ",
            @"delete": @"\x7f", @"esc": @"\x1b",
            @"left": [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
            @"right": [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
            @"up": [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey],
            @"down": [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
        };
    });
    return special[name] ?: name;
}

// What `characters` carries when shift is held. uppercaseString covers letters
// alone, so the digits get their US-layout shifted forms explicitly. The
// specials and arrows are shift-invariant either way.
static NSString *VibeShiftedKeyCharacters(NSString *chars) {
    static NSDictionary<NSString *, NSString *> *shifted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shifted = @{
            @"1": @"!", @"2": @"@", @"3": @"#", @"4": @"$", @"5": @"%",
            @"6": @"^", @"7": @"&", @"8": @"*", @"9": @"(", @"0": @")",
        };
    });
    return shifted[chars] ?: chars.uppercaseString;
}

static BOOL VibeKeyIsArrow(NSString *name) {
    return [@[@"left", @"right", @"up", @"down"] containsObject:name];
}

// Any tokens trailing the key name are modifier names.
static BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start,
                               NSEventModifierFlags *outFlags, NSString **errorJSON) {
    NSEventModifierFlags flags = 0;
    for (NSUInteger i = start; i < tokens.count; i++) {
        NSString *mod = tokens[i].lowercaseString;
        if ([mod isEqualToString:@"shift"]) {
            flags |= NSEventModifierFlagShift;
        }
        else if ([mod isEqualToString:@"cmd"] || [mod isEqualToString:@"command"]) {
            flags |= NSEventModifierFlagCommand;
        }
        else if ([mod isEqualToString:@"opt"] || [mod isEqualToString:@"option"] || [mod isEqualToString:@"alt"]) {
            flags |= NSEventModifierFlagOption;
        }
        else if ([mod isEqualToString:@"ctrl"] || [mod isEqualToString:@"control"]) {
            flags |= NSEventModifierFlagControl;
        }
        else {
            *errorJSON = VibeErrorJSON(@"unknown modifier '%@' (shift, cmd, opt, ctrl)", tokens[i]);
            return NO;
        }
    }
    *outFlags = flags;
    return YES;
}

// key posts a down and an up, while key_down and key_up post one edge each.
// That split is how the held W, E, R and T momentary FX keys are driven, since
// TransportKeyMonitor releases on keyUp.
static NSString *VibeInjectKey(MainPlayerController *controller, NSArray<NSString *> *tokens,
                               BOOL down, BOOL up) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: %@ <key> [shift|cmd|opt|ctrl ...]", verb);
    }
    NSString *name = tokens[1].lowercaseString;
    NSNumber *code = VibeKeyCodeMap()[name];
    if (!code) {
        return VibeErrorJSON(@"unknown key '%@' (a-z, 0-9, space, tab, return, esc, delete, up, down, left, right)",
                tokens[1]);
    }
    NSEventModifierFlags flags = 0;
    NSString *errorJSON = nil;
    if (!VibeParseModifiers(tokens, 2, &flags, &errorJSON)) {
        return errorJSON;
    }
    if (VibeKeyIsArrow(name)) {
        // Real arrow events carry these, and some responders check them.
        flags |= NSEventModifierFlagFunction | NSEventModifierFlagNumericPad;
    }
    NSString *chars = VibeKeyCharacters(name);
    // charactersIgnoringModifiers ignores Option, NOT Shift: hardware delivers
    // the shifted character in BOTH fields, and AppKit's menu key-equivalent
    // matching reads it — a lowercase char there makes ⇧⌘C match a plain ⌘C
    // equivalent instead of the ⇧⌘C one.
    NSString *charsWithMods = (flags & NSEventModifierFlagShift) ? VibeShiftedKeyCharacters(chars) : chars;
    NSWindow *window = controller.window;
    void (^post)(NSEventType) = ^(NSEventType type) {
        NSEvent *event = [NSEvent keyEventWithType:type
                                          location:NSZeroPoint
                                     modifierFlags:flags
                                         timestamp:VibeEventTimestamp()
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:charsWithMods
                       charactersIgnoringModifiers:charsWithMods
                                         isARepeat:NO
                                           keyCode:code.unsignedShortValue];
        [NSApp postEvent:event atStart:NO];
    };
    if (down) {
        post(NSEventTypeKeyDown);
    }
    if (up) {
        post(NSEventTypeKeyUp);
    }
    return VibeJSONString(@{@"ok": @YES, @"posted": verb, @"key": name});
}

// The shared tail for the mouse verbs. It converts to bottom-left window
// coordinates, posts through the block, and replies with the hit-tested view,
// so that a missed aim is visible in the reply rather than silently doing
// nothing.
static NSString *VibeMouseReply(NSString *verb, NSWindow *window, NSPoint location,
                                double x, double y) {
    NSView *content = window.contentView;
    NSView *hit = (content && content.superview)
            ? [content hitTest:[content.superview convertPoint:location fromView:nil]]
            : nil;
    return VibeJSONString(@{
        @"ok": @YES,
        @"posted": verb,
        @"x": @(x),
        @"y": @(y),
        @"hitView": hit ? hit.className : (id)NSNull.null,
        @"windowKey": @(window.isKeyWindow),
    });
}

// A non-key window swallows the first click as activation, because
// acceptsFirstMouse defaults to NO as click-through protection, so mouse
// injection self-activates first. It uses the deprecated force spelling,
// because the cooperative [NSApp activate] is declined while another app is
// frontmost, which is exactly the state a shell-driven test runs in.
// Activation lands asynchronously, so spin the run loop briefly until key
// status arrives: events posted before that are swallowed. The reply's
// windowKey reports whether it took.
static void VibeMakeWindowKeyForInjection(NSWindow *window) {
    if (window.isKeyWindow) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    [window makeKeyAndOrderFront:nil];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!window.isKeyWindow && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static NSEvent *VibeMouseEvent(NSEventType type, NSPoint location, NSInteger windowNumber,
                               NSInteger clickCount, float pressure) {
    return [NSEvent mouseEventWithType:type
                              location:location
                         modifierFlags:0
                             timestamp:VibeEventTimestamp()
                          windowNumber:windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:clickCount
                              pressure:pressure];
}

// click, mouse_down, mouse_up and mouse_move. mouse_move with a button token
// posts a *dragged* event, and a plain move otherwise. CAUTION: a lone
// mouse_down on a control that runs a modal mouse-tracking loop stalls the app
// inside that loop, and the command channel, on the GCD main queue, cannot
// deliver the matching mouse_up while it spins. Use `click` or `drag`, whose
// events are all queued before the loop starts.
static NSString *VibeInjectMouse(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    NSString *verb = tokens.firstObject;
    BOOL isClick = [verb isEqualToString:@"click"];
    NSString *usage = isClick
            ? @"usage: click <x> <y> [left|right] [clickCount]"
            : [NSString stringWithFormat:@"usage: %@ <x> <y> [left|right]", verb];
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSUInteger next = 3;
    BOOL right = NO;
    BOOL haveButton = NO;
    if (tokens.count > next) {
        NSString *button = tokens[next].lowercaseString;
        if ([button isEqualToString:@"left"] || [button isEqualToString:@"right"]) {
            right = [button isEqualToString:@"right"];
            haveButton = YES;
            next++;
        }
    }
    NSInteger clickCount = 1;
    if (isClick && tokens.count > next) {
        clickCount = tokens[next].integerValue;
        if (clickCount < 1 || clickCount > 3) {
            return VibeErrorJSON(@"clickCount must be 1-3");
        }
        next++;
    }
    if (tokens.count > next) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSWindow *window = controller.window;
    VibeMakeWindowKeyForInjection(window);
    NSPoint location = NSMakePoint(x, NSHeight(window.frame) - y);
    NSInteger windowNumber = window.windowNumber;
    if (isClick) {
        // A double-click is two full press cycles with an ascending
        // clickCount, exactly as the window server delivers one.
        for (NSInteger i = 1; i <= clickCount; i++) {
            [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown,
                                            location, windowNumber, i, 1.0) atStart:NO];
            [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp,
                                            location, windowNumber, i, 0.0) atStart:NO];
        }
    }
    else if ([verb isEqualToString:@"mouse_down"]) {
        [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown,
                                        location, windowNumber, 1, 1.0) atStart:NO];
    }
    else if ([verb isEqualToString:@"mouse_up"]) {
        [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp,
                                        location, windowNumber, 1, 0.0) atStart:NO];
    }
    else { // mouse_move
        NSEventType type = !haveButton ? NSEventTypeMouseMoved
                : (right ? NSEventTypeRightMouseDragged : NSEventTypeLeftMouseDragged);
        [NSApp postEvent:VibeMouseEvent(type, location, windowNumber, 0, haveButton ? 1.0 : 0.0)
                 atStart:NO];
    }
    return VibeMouseReply(verb, window, location, x, y);
}

// A full left-button drag gesture queued in one command: down, interpolated
// dragged steps, up. It is the only injection shape that works on
// tracking-loop controls; see VibeInjectMouse.
static NSString *VibeInjectDrag(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    NSString *usage = @"usage: drag <x1> <y1> <x2> <y2> [steps]";
    double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    if (tokens.count < 5
            || !VibeParseDouble(tokens[1], &x1) || !VibeParseDouble(tokens[2], &y1)
            || !VibeParseDouble(tokens[3], &x2) || !VibeParseDouble(tokens[4], &y2)) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSInteger steps = 12;
    if (tokens.count >= 6) {
        steps = tokens[5].integerValue;
        if (steps < 2 || steps > 200) {
            return VibeErrorJSON(@"steps must be 2-200");
        }
    }
    if (tokens.count > 6) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSWindow *window = controller.window;
    VibeMakeWindowKeyForInjection(window);
    CGFloat height = NSHeight(window.frame);
    NSInteger windowNumber = window.windowNumber;
    NSPoint start = NSMakePoint(x1, height - y1);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDown, start, windowNumber, 1, 1.0)
             atStart:NO];
    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        NSPoint p = NSMakePoint(x1 + (x2 - x1) * t, height - (y1 + (y2 - y1) * t));
        [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDragged, p, windowNumber, 1, 1.0)
                 atStart:NO];
    }
    NSPoint end = NSMakePoint(x2, height - y2);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseUp, end, windowNumber, 1, 0.0)
             atStart:NO];
    return VibeMouseReply(@"drag", window, start, x1, y1);
}

#pragma mark Synthetic file drags

// drag_hover, drag_drop and drag_end drive the same FileDropDelegate path a
// real external file drag takes through MainWindow. A genuine
// NSDraggingSession cannot be synthesized, because only the window server can
// start one, which is what makes the playlist drop zone untestable through the
// event verbs above. These are direct delegate calls rather than posted
// events. Coordinates are main-window points with a top-left origin, as with
// the mouse verbs.

static NSString *VibeWellName(PlaylistDropWellAction action) {
    switch (action) {
        case PlaylistDropWellActionReplace: return @"replace";
        case PlaylistDropWellActionAdd:     return @"add";
        case PlaylistDropWellActionNone:    return @"none";
    }
}

// The shared coordinate parse and conversion for drag_hover and drag_drop. It
// returns NO with *errorJSON set on a malformed pair.
static BOOL VibeDragPointArgument(NSArray<NSString *> *tokens, NSWindow *window,
                                  NSPoint *outLocation, double *outX, double *outY,
                                  NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <x> <y>%@", verb,
                [verb isEqualToString:@"drag_drop"] ? @" <file-or-directory>" : @"");
        return NO;
    }
    *outX = x;
    *outY = y;
    *outLocation = NSMakePoint(x, NSHeight(window.frame) - y); // → bottom-left window coords
    return YES;
}

static NSString *VibeSyntheticDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if ([window.dropDelegate respondsToSelector:@selector(mainWindow:fileDraggingUpdatedAtLocation:)]) {
        [window.dropDelegate mainWindow:window fileDraggingUpdatedAtLocation:location];
    }
    // Which well the point resolves to, meaning what a drop here would do:
    // the assertable part of the reply.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"drag_hover",
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

static NSString *VibeSyntheticDragEnd(MainPlayerController *controller) {
    MainWindow *window = (MainWindow *)controller.window;
    if ([window.dropDelegate respondsToSelector:@selector(mainWindowFileDraggingEnded:)]) {
        [window.dropDelegate mainWindowFileDraggingEnded:window];
    }
    return VibeJSONString(@{@"ok": @YES, @"posted": @"drag_end"});
}

static NSString *VibeSyntheticDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if (tokens.count < 4) {
        return VibeErrorJSON(@"usage: drag_drop <x> <y> <file-or-directory>");
    }
    NSString *path = [[tokens subarrayWithRange:NSMakeRange(3, tokens.count - 3)]
            componentsJoinedByString:@" "].stringByExpandingTildeInPath;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return VibeErrorJSON(@"no file or directory at '%@'", path);
    }
    // Resolved before anything mutates, purely for the reply. The geometry is
    // independent of drag state, and the real delivery below re-resolves it.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    // Mirror performDragOperation:'s pipeline and ordering: start the async
    // expand and deliver, then tear the drag-over presentation down. A real
    // drop gets draggingEnded right after performDragOperation returns. The
    // sandbox caveat is the same as with `open`: an ungranted path may be
    // denied at read time. Poll dump_state for the resulting playlist.
    [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                        completion:^(NSArray<NSURL *> *expanded, NSUInteger folderCount) {
        if (expanded.count > 0 &&
            [window.dropDelegate respondsToSelector:@selector(mainWindow:filesDropped:atLocation:)]) {
            [window.dropDelegate mainWindow:window filesDropped:expanded atLocation:location];
        }
    }];
    if ([window.dropDelegate respondsToSelector:@selector(mainWindowFileDraggingEnded:)]) {
        [window.dropDelegate mainWindowFileDraggingEnded:window];
    }
    return VibeJSONString(@{@"ok": @YES, @"dropping": path,
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

#pragma mark Command table

// One handler per verb, where tokens[0] is the verb itself. Returning nil
// means the command completes asynchronously and writes its own response later
// through VibeWriteDebugResponse(commandId, ...), from a completion block.
typedef NSString * _Nullable (^VibeDebugCommandHandler)(NSArray<NSString *> *tokens,
                                                        NSString *commandId,
                                                        MainPlayerController *controller);

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
        [undoManager redo];
    }
    else {
        [undoManager undo];
    }
    return nil; // response written by the settled hook
}

// The command set. Dispatch, the unknown-command usage reply and the client's
// per-verb wait all derive from this table, so adding an entry here is the
// entire app-side hookup. The usage docs live in the vibe-debug skill.
static NSArray<NSDictionary *> *VibeDebugCommandTable(void) {
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
                VibeDumpWindowSnapshot(path);
                return VibeJSONString(@{@"path": path});
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
            VibeCmd(@"set_window_width <body-points>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
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
                frame.size.width = MAX(window.minSize.width, tokens[1].doubleValue + panel);
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
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_pitch <percent>");
                }
                // Through the panel first, so that the fader clamps to its
                // range exactly as a drag would, and then the player takes the
                // clamped value.
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
        ];
    });
    return table;
}

static NSString *VibeVerbFromUsage(NSString *usage) {
    NSRange space = [usage rangeOfString:@" "];
    return space.location == NSNotFound ? usage : [usage substringToIndex:space.location];
}

NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    for (NSDictionary *spec in VibeDebugCommandTable()) {
        if ([VibeVerbFromUsage(spec[@"usage"]) isEqualToString:verb]) {
            return spec;
        }
    }
    return nil;
}

// Returns the JSON response to write, or nil if the command completes
// asynchronously and writes its own response through VibeWriteDebugResponse.
// file_cache does that, since it runs a full waveform decode off the main
// thread.
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
        // The unknown-command reply is the channel's authoritative command
        // list, and CLAUDE.md points here, so it must also advertise the verbs
        // the CLI client runs in its own process without ever posting a
        // command file; see VibeDebugCommandClientMain.
        NSMutableArray<NSString *> *usages = [NSMutableArray array];
        for (NSDictionary *entry in VibeDebugCommandTable()) {
            [usages addObject:entry[@"usage"]];
        }
        [usages addObject:@"clear_disk_caches"];
        [usages addObject:@"set_appearance <light|dark|system>"];
        [usages addObject:@"set_analysis <bpm|key> <on|off>"];
        [usages addObject:@"set_key_display <camelot|musical> <colors|plain>"];
        [usages addObject:@"sleep <seconds>"];
        [usages addObject:@"script <file | ->"];
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
    // A malformed payload still gets an {"error": ...} reply whenever the id
    // is recoverable. A silent drop leaves the client polling out its window
    // and blaming a missing debug build.
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
    // own response through VibeWriteDebugResponse when done, as file_cache does.
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
    LogInfo(@"Debug command dispatched: %@", [args componentsJoinedByString:@" "]);
}

// notify_post coalesces back-to-back posts into one delivery, so a single
// wake-up must drain every pending command file. Each reply pairs with its
// command through the id.
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
    // Sweep files orphaned by earlier runs. An async verb that outlives its
    // client's poll window writes a response no one ever deletes, because the
    // client cleans up only its command file, so vibe-response-*.txt litter
    // accumulates in the container tmp until the OS purges it, as does any
    // per-command vibe-screenshot-*.png a client never streamed. Stale
    // vibe-command-*.json files are the dangerous ones: a client killed
    // mid-poll leaves its command behind, and the next notification's drain
    // would EXECUTE it — a days-old convert_to_flac delete, out of nowhere.
    // Anything present before this hook is live belongs to a dead
    // conversation, so delete all three kinds.
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in names) {
        if (([name hasPrefix:@"vibe-response-"] && [name hasSuffix:@".txt"])
                || ([name hasPrefix:@"vibe-screenshot-"] && [name hasSuffix:@".png"])
                || ([name hasPrefix:@"vibe-command-"] && [name hasSuffix:@".json"])) {
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

#endif
