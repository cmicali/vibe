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
#import "MainPlayerController+Transport.h"
#import "TrackDisplayController.h"
#import "MainWindow.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"
#import "PlaylistController.h"
#import "PlaylistDropZoneView.h"
#import "MainPlayerContentView.h"
#import "NSURLUtil.h"
#import "PitchControlPanel.h"
#import "SymbolButton.h"

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
            @"outputDeviceId": @(player.currentlyActiveAudioDeviceId),
            @"silent": @([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]),
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
            @"title": controller.trackDisplay.titleTextField.stringValue ?: @"",
            @"artist": controller.trackDisplay.artistTextField.stringValue ?: @"",
            @"currentTime": controller.trackDisplay.currentTimeTextField.stringValue ?: @"",
            @"totalTime": controller.trackDisplay.totalTimeTextField.stringValue ?: @"",
            @"fileMetadata": controller.trackDisplay.fileMetadataTextField.stringValue ?: @"",
            @"timeLabelsHidden": @(controller.trackDisplay.currentTimeTextField.isHidden),
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

#pragma mark Input injection

// Synthesized NSEvents posted into the app's own event queue
// ([NSApp postEvent:atStart:NO]). Unlike --debug-cmd's direct action calls,
// these exercise the real event dispatch path — local monitors
// (TransportKeyMonitor) and view mouse handling included — and unlike CGEvent
// injection (input.swift) they need no Accessibility permission and no
// frontmost window. Two structural limits versus real window-server events:
// tracking areas / hover effects don't fire (the window server drives those),
// and the posted events are processed after the reply is written — poll
// dump_state to observe the result.
//
// Mouse coordinates are MAIN-WINDOW POINTS, ORIGIN TOP-LEFT — the same frame
// of reference as dump_screenshot (retina pixel / 2). NSEvent wants
// bottom-left window coords, converted here.

static NSTimeInterval VibeEventTimestamp(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static BOOL VibeParseDouble(NSString *token, double *out) {
    NSScanner *scanner = [NSScanner scannerWithString:token];
    return [scanner scanDouble:out] && scanner.isAtEnd;
}

static NSDictionary<NSString *, NSNumber *> *VibeKeyCodeMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ANSI virtual key codes (HIToolbox Events.h values, stated inline so
        // Carbon stays unimported).
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

static BOOL VibeKeyIsArrow(NSString *name) {
    return [@[@"left", @"right", @"up", @"down"] containsObject:name];
}

// Trailing tokens after the key name are modifier names.
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

// key = down+up; key_down / key_up post one edge — that split is how the held
// W/E/R/T momentary FX keys are driven (TransportKeyMonitor releases on keyUp).
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
        // Real arrow events carry these; some responders check them.
        flags |= NSEventModifierFlagFunction | NSEventModifierFlagNumericPad;
    }
    NSString *chars = VibeKeyCharacters(name);
    NSString *charsWithMods = (flags & NSEventModifierFlagShift) ? chars.uppercaseString : chars;
    NSWindow *window = controller.window;
    void (^post)(NSEventType) = ^(NSEventType type) {
        NSEvent *event = [NSEvent keyEventWithType:type
                                          location:NSZeroPoint
                                     modifierFlags:flags
                                         timestamp:VibeEventTimestamp()
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:charsWithMods
                       charactersIgnoringModifiers:chars
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

// Shared tail for the mouse verbs: convert to bottom-left window coords, post
// via the block, and reply with the hit-tested view so a missed aim is visible
// in the reply instead of silently doing nothing.
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

// A non-key window swallows the first click as activation (click-through
// protection: acceptsFirstMouse defaults NO), so mouse injection self-
// activates first — the deprecated force spelling, because the cooperative
// [NSApp activate] is declined while another app is frontmost (tested), which
// is exactly the state a shell-driven test runs in. Activation lands
// asynchronously, so spin the run loop briefly until key status arrives —
// events posted before that are swallowed. The reply's windowKey reports
// whether it took.
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

// click / mouse_down / mouse_up / mouse_move. mouse_move with a button token
// posts a *dragged* event (a plain move otherwise). CAUTION: a lone mouse_down
// on a control that runs a modal mouse-tracking loop stalls the app inside
// that loop, and the command channel (GCD main queue) can't deliver the
// matching mouse_up while it spins — use `click` or `drag`, whose events are
// all queued before the loop starts.
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
        // A double-click is two full press cycles with ascending clickCount,
        // exactly as the window server delivers one.
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

// Full left-button drag gesture queued in one command (down, interpolated
// dragged steps, up) — the only injection shape that works on tracking-loop
// controls (see VibeInjectMouse).
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

// drag_hover / drag_drop / drag_end drive the SAME FileDropDelegate path a
// real external file drag takes through MainWindow — a genuine
// NSDraggingSession can't be synthesized (only the window server can start
// one), which is what makes the playlist drop zone untestable via the event
// verbs above. These are direct delegate calls, not posted events.
// Coordinates are main-window points, origin top-left, like the mouse verbs.

static NSString *VibeWellName(PlaylistDropWellAction action) {
    switch (action) {
        case PlaylistDropWellActionReplace: return @"replace";
        case PlaylistDropWellActionAdd:     return @"add";
        case PlaylistDropWellActionNone:    return @"none";
    }
}

// Shared coordinate parse + conversion for drag_hover/drag_drop. Returns NO
// with *errorJSON set on a malformed pair.
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
    // Which well the point resolves to (what a drop here would do) — the
    // assertable part of the reply.
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
    // Resolved before anything mutates, purely for the reply (the geometry is
    // drag-state independent — the real delivery below re-resolves it).
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    // Mirror performDragOperation:'s pipeline and ordering: start the async
    // expand-and-deliver, then tear the drag-over presentation down (real
    // drops get draggingEnded right after performDragOperation returns).
    // Sandbox caveat as with `open`: an ungranted path may be denied at read
    // time. Poll dump_state for the resulting playlist.
    [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                        completion:^(NSArray<NSURL *> *expanded) {
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
            VibeCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // Arguments are client-side: "-" streams the PNG bytes to
                // stdout; in a script the reply carries the PNG as base64 and
                // a label names the decoded file (run-script.sh).
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
            VibeCmd(@"set_window_width <body-points>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_window_width <body-points>");
                }
                // The window is freely resizable and its width comes back from
                // the frame autosave, so a screenshot run that wants a
                // reproducible size has to set one. The argument is the BODY
                // width — the player without the pitch panel's slice, i.e. what
                // MainPlayerContentView lays out at and what
                // kMainWindowContentWidth names — so the number means the same
                // thing whether or not the panel happens to be out.
                MainWindow *window = (MainWindow *)controller.window;
                CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
                NSRect frame = window.frame;
                // Grows to the right like a resize-handle drag, floored by the
                // window's own minSize (which already carries the panel), then
                // pulled back on-screen — a window hanging off the right edge
                // captures clipped.
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
        // The unknown-command reply is the channel's authoritative command
        // list (CLAUDE.md points here), so it must also advertise the verbs
        // the CLI client executes in its own process without ever posting a
        // command file (see VibeDebugCommandClientMain).
        NSMutableArray<NSString *> *usages = [NSMutableArray array];
        for (NSDictionary *entry in VibeDebugCommandTable()) {
            [usages addObject:entry[@"usage"]];
        }
        [usages addObject:@"clear_disk_caches"];
        [usages addObject:@"set_appearance <light|dark|system>"];
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

// Script-mode replies are re-serialized compact — one line per command — so
// script output is real NDJSON a wrapper can line-split (run-script.sh does).
// Top-level replies keep the human-friendly pretty print.
static void VibeClientPrintReply(NSString *json, BOOL inScript) {
    if (inScript) {
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSData *compact = object
                ? [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil]
                : nil;
        NSString *line = compact ? [[NSString alloc] initWithData:compact encoding:NSUTF8StringEncoding] : nil;
        if (line) {
            json = line;
        }
    }
    printf("%s\n", json.UTF8String);
}

// Runs one command — local verbs in this process, everything else over the
// channel — printing its reply line and returning the exit code. Called both
// by the top-level main and per script line (inScript switches the verbs
// whose I/O contract can't compose with NDJSON-lines output: dump_screenshot
// replies carry the PNG as base64 instead of streaming raw bytes, and
// stdin-streaming scan_bpm - and nested script are rejected).
static int VibeDebugClientRunOne(NSArray<NSString *> *args, BOOL inScript) {
    @autoreleasepool {
        // Client-side pause, for scripts: the app's main thread never sleeps.
        if ([args.firstObject isEqualToString:@"sleep"]) {
            double seconds = 0;
            BOOL valid = args.count == 2 && VibeParseDouble(args[1], &seconds)
                    && seconds > 0 && seconds <= 600;
            if (!valid) {
                fprintf(stderr, "usage: Vibe --debug-cmd sleep <seconds 0-600>\n");
                return 64;
            }
            usleep((useconds_t)(seconds * 1e6));
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"slept": @(seconds)}), inScript);
            return 0;
        }
        if (inScript && [args.firstObject isEqualToString:@"script"]) {
            fprintf(stderr, "vibe: scripts cannot nest\n");
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
                if (inScript) {
                    // The script source may itself be riding stdin.
                    fprintf(stderr, "vibe: scan_bpm - (stdin) is not available inside a script — pass a file path\n");
                    return 64;
                }
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
            VibeClientPrintReply(json, inScript);
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
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"cleared": cleared}), inScript);
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
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"windowAppearance": args[1]}), inScript);
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
                // dump_screenshot payload delivery. Only this process may
                // read the PNG — it lives in the app container, and another
                // process reading it trips macOS 14+ app-data protection; the
                // inherited stdout fd crosses the sandbox freely.
                // Top level, `dump_screenshot -`: raw PNG bytes to stdout
                // (JSON reply moves to stderr); the caller opens its own
                // redirect target. In a script: the reply line carries the
                // PNG base64-encoded (raw bytes can't interleave with
                // one-JSON-object-per-line output) plus any label argument —
                // run-script.sh decodes them to numbered files.
                if (!failed && [args.firstObject isEqualToString:@"dump_screenshot"]
                            && (inScript || [args containsObject:@"-"])) {
                    NSString *pngPath = [reply[@"path"] isKindOfClass:NSString.class] ? reply[@"path"] : nil;
                    NSData *png = pngPath ? [NSData dataWithContentsOfFile:pngPath] : nil;
                    if (png.length == 0) {
                        fprintf(stderr, "vibe: no screenshot at %s\n",
                                pngPath.fileSystemRepresentation ?: "(no path in reply)");
                        return 2;
                    }
                    if (inScript) {
                        NSMutableDictionary *out = [NSMutableDictionary dictionary];
                        out[@"ok"] = @YES;
                        out[@"pngBase64"] = [png base64EncodedStringWithOptions:0];
                        for (NSUInteger i = 1; i < args.count; i++) {
                            if (![args[i] isEqualToString:@"-"]) {
                                out[@"label"] = args[i];
                                break;
                            }
                        }
                        VibeClientPrintReply(VibeJSONString(out), YES);
                        return 0;
                    }
                    fwrite(png.bytes, 1, png.length, stdout);
                    fprintf(stderr, "%s\n", response.UTF8String);
                    return 0;
                }
                if (response.length) {
                    VibeClientPrintReply(response, inScript);
                }
                return failed ? 2 : 0;
            }
        }
        [fileManager removeItemAtPath:commandPath error:nil];
        fprintf(stderr, "vibe: no response after %.0fs — is a debug build of Vibe running?\n", timeout);
        return 1;
    }
}

#pragma mark Script mode

// Whitespace-splits one script line into tokens; single or double quotes
// group a token containing spaces (no escape sequences — this is a command
// list, not a shell). Returns nil with *error set on an unterminated quote.
static NSArray<NSString *> *VibeTokenizeScriptLine(NSString *line, NSString **error) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSMutableString *current = nil;
    unichar quote = 0;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar ch = [line characterAtIndex:i];
        if (quote) {
            if (ch == quote) {
                quote = 0;
            }
            else {
                [current appendFormat:@"%C", ch];
            }
        }
        else if (ch == '\'' || ch == '"') {
            quote = ch;
            if (!current) {
                current = [NSMutableString string];
            }
        }
        else if (ch == ' ' || ch == '\t') {
            if (current) {
                [tokens addObject:current];
                current = nil;
            }
        }
        else {
            if (!current) {
                current = [NSMutableString string];
            }
            [current appendFormat:@"%C", ch];
        }
    }
    if (quote) {
        *error = @"unterminated quote";
        return nil;
    }
    if (current) {
        [tokens addObject:current];
    }
    return tokens;
}

// One command per line, run in order; blank lines and full-line # comments
// are skipped. Output is one JSON reply per command (NDJSON). Stops at the
// first failing command and returns its exit code, so a script doubles as a
// test: exit 0 means every command succeeded.
static int VibeDebugClientRunScript(NSString *source) {
    NSUInteger lineNumber = 0;
    for (NSString *rawLine in [source componentsSeparatedByString:@"\n"]) {
        lineNumber++;
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) {
            continue;
        }
        NSString *error = nil;
        NSArray<NSString *> *tokens = VibeTokenizeScriptLine(line, &error);
        if (!tokens) {
            fprintf(stderr, "vibe: script line %lu: %s\n", (unsigned long)lineNumber, error.UTF8String);
            return 64;
        }
        if (tokens.count == 0) {
            continue;
        }
        int status = VibeDebugClientRunOne(tokens, YES);
        if (status != 0) {
            fprintf(stderr, "vibe: script line %lu failed (exit %d): %s\n",
                    (unsigned long)lineNumber, status,
                    [tokens componentsJoinedByString:@" "].UTF8String);
            return status;
        }
    }
    return 0;
}

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
        if ([args.firstObject isEqualToString:@"script"]) {
            if (args.count != 2) {
                fprintf(stderr, "usage: Vibe --debug-cmd script <file | ->\n");
                return 64;
            }
            NSString *source;
            if ([args[1] isEqualToString:@"-"]) {
                NSData *data = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
                source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            else {
                source = [NSString stringWithContentsOfFile:args[1].stringByExpandingTildeInPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
            }
            if (!source) {
                // Usually the sandbox: this process can't read arbitrary user
                // paths (same as argv audio files). stdin always crosses.
                fprintf(stderr, "vibe: cannot read script '%s' (sandbox?) — use: script - < %s\n",
                        [args[1] UTF8String], [args[1] UTF8String]);
                return 64;
            }
            return VibeDebugClientRunScript(source);
        }
        return VibeDebugClientRunOne(args, NO);
    }
}

#endif
