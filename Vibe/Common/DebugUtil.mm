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
#import <notify.h>
// Pulls in MainPlayerController, MainWindow, AudioPlayer, PlaylistManager,
// AudioTrack, PitchControlPanel — everything the command dispatch touches.
#import "AppDelegate.h"

static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
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
            kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        return;
    }
    CGContextScaleCTM(ctx, scale, scale);
    CALayer *layer = view.layer;
    if (layer) {
        // Presentation tree when available: captures animations mid-flight.
        CALayer *presentation = layer.presentationLayer ?: layer;
        [presentation renderInContext:ctx];
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

static NSString *VibeDebugCommandPath(void) {
    return VibeDebugTmpPath(@"vibe-command.json");
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

static NSString *VibeJSONString(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return json ?: @"ERROR: state not JSON-serializable";
}

static void VibeAppendViewTree(NSView *view, NSUInteger depth, NSMutableString *out) {
    [out appendString:[@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0]];
    [out appendFormat:@"%@ %p", view.className, view];
    if (view.identifier.length) {
        [out appendFormat:@" id=%@", view.identifier];
    }
    [out appendFormat:@" frame=%@", NSStringFromRect(view.frame)];
    if (view.isHidden) {
        [out appendString:@" hidden"];
    }
    if (view.alphaValue < 1.0) {
        [out appendFormat:@" alpha=%.2f", view.alphaValue];
    }
    if (view.autoresizingMask != NSViewNotSizable) {
        [out appendFormat:@" mask=0x%lx", (unsigned long)view.autoresizingMask];
    }
    [out appendString:@"\n"];
    for (NSView *subview in view.subviews) {
        VibeAppendViewTree(subview, depth + 1, out);
    }
}

static NSString *VibeViewTreeDump(void) {
    NSMutableString *out = [NSMutableString string];
    for (NSWindow *window in NSApp.windows) {
        [out appendFormat:@"%@ %p \"%@\" frame=%@ visible=%d key=%d\n",
                          window.className, window, window.title, NSStringFromRect(window.frame),
                          window.isVisible, window.isKeyWindow];
        if (window.contentView) {
            VibeAppendViewTree(window.contentView, 1, out);
        }
    }
    return out;
}

static void VibeAppendMenuTree(NSMenu *menu, NSUInteger depth, NSMutableString *out) {
    // Runs validateMenuItem exactly like opening the menu would, so
    // enabled/checkmark below are live, not stale defaults. Also fires
    // menuNeedsUpdate for delegate-built menus (Open Recent, waveform styles).
    [menu update];
    for (NSMenuItem *item in menu.itemArray) {
        NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
        if (item.isSeparatorItem) {
            [out appendFormat:@"%@---\n", indent];
            continue;
        }
        [out appendFormat:@"%@\"%@\"", indent, item.title];
        if (item.identifier.length) {
            [out appendFormat:@" id=%@", item.identifier];
        }
        if (item.keyEquivalent.length) {
            NSString *key = [item.keyEquivalent stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
            [out appendFormat:@" key=\"%@\"", key];
            if (item.keyEquivalentModifierMask) {
                [out appendFormat:@" mods=0x%lx", (unsigned long)item.keyEquivalentModifierMask];
            }
        }
        if (item.action) {
            [out appendFormat:@" action=%@", NSStringFromSelector(item.action)];
        }
        [out appendFormat:@" enabled=%d", item.isEnabled];
        if (item.state != NSControlStateValueOff) {
            [out appendFormat:@" state=%ld", (long)item.state];
        }
        [out appendString:@"\n"];
        if (item.submenu) {
            VibeAppendMenuTree(item.submenu, depth + 1, out);
        }
    }
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
        return [NSString stringWithFormat:@"ERROR: no menu item with identifier or title '%@' (run `menu` to list)", name];
    }
    [item.menu update]; // same validation pass opening the menu would run
    if (!item.isEnabled) {
        return [NSString stringWithFormat:@"ERROR: menu item '%@' is disabled", item.title];
    }
    if (!item.action) {
        return [NSString stringWithFormat:@"ERROR: menu item '%@' has no action", item.title];
    }
    if (![NSApp sendAction:item.action to:item.target from:item]) {
        return [NSString stringWithFormat:@"ERROR: no responder handled %@", NSStringFromSelector(item.action)];
    }
    return [NSString stringWithFormat:@"ok clicked \"%@\" (%@)", item.title, NSStringFromSelector(item.action)];
}

// One-line result for action commands: enough to assert on without a second
// `state` round-trip. Transport actions kick off async engine work, so state
// here can be a beat behind (it's read synchronously after the call).
static NSString *VibeActionSummary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    return [NSString stringWithFormat:
            @"ok state=%@ index=%lu/%lu position=%.2f pitch=%+.1f playlistShown=%d pitchPanelShown=%d",
            VibePlayerStateName(player),
            (unsigned long)controller.playlistManager.currentIndex,
            (unsigned long)controller.playlistManager.count,
            player.position, player.pitch,
            window.isPlaylistShown, window.isPitchPanelShown];
}

static NSString *VibeExecuteDebugCommand(NSString *commandLine) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [commandLine componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet]) {
        if (token.length) {
            [tokens addObject:token];
        }
    }
    NSString *verb = tokens.firstObject ?: @"";

    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    MainPlayerController *controller = [appDelegate isKindOfClass:AppDelegate.class]
            ? appDelegate.mainPlayerController : nil;
    if (!controller) {
        return @"ERROR: app not fully launched";
    }
    AudioPlayer *player = controller.audioPlayer;

    if ([verb isEqualToString:@"state"]) {
        return VibeJSONString(VibeStateDictionary(controller));
    }
    if ([verb isEqualToString:@"viewtree"]) {
        return VibeViewTreeDump();
    }
    if ([verb isEqualToString:@"menu"]) {
        NSMutableString *out = [NSMutableString string];
        VibeAppendMenuTree(NSApp.mainMenu, 0, out);
        return out;
    }
    if ([verb isEqualToString:@"clickMenu"]) {
        if (tokens.count < 2) {
            return @"ERROR: usage: clickMenu <identifier-or-title>";
        }
        // Rest of the line, so exact titles with spaces work too.
        NSString *name = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
                componentsJoinedByString:@" "];
        return VibeClickMenuItem(name);
    }
    if ([verb isEqualToString:@"screenshot"]) {
        VibeDumpWindowSnapshot();
        return VibeDebugScreenshotPath();
    }
    if ([verb isEqualToString:@"playPause"]) {
        [controller playPause:nil];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"next"]) {
        [controller next:nil];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"previous"]) {
        [controller previous:nil];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"togglePitchPanel"]) {
        [controller togglePitchPanel:nil];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"toggleSize"]) {
        [controller toggleSize:nil];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"setPitch"]) {
        if (tokens.count < 2) {
            return @"ERROR: usage: setPitch <percent>";
        }
        // Through the panel first so the fader clamps to its range exactly
        // like a drag, then the player takes the clamped value.
        controller.pitchPanel.pitch = tokens[1].floatValue;
        player.pitch = controller.pitchPanel.pitch;
        [controller debugRefreshUI];
        return VibeActionSummary(controller);
    }
    if ([verb isEqualToString:@"seek"]) {
        if (tokens.count < 2) {
            return @"ERROR: usage: seek <seconds>";
        }
        player.position = tokens[1].doubleValue;
        [controller debugRefreshUI];
        return VibeActionSummary(controller);
    }
    return [NSString stringWithFormat:
            @"ERROR: unknown command '%@'. Commands: state, viewtree, menu, screenshot, playPause, "
            @"next, previous, togglePitchPanel, toggleSize, setPitch <percent>, seek <seconds>, "
            @"clickMenu <identifier-or-title>", verb];
}

static void VibeHandleDebugCommandFile(void) {
    NSData *data = [NSData dataWithContentsOfFile:VibeDebugCommandPath()];
    if (!data) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:VibeDebugCommandPath() error:nil];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSString *commandId = payload[@"id"];
    NSString *command = payload[@"command"];
    if (![commandId isKindOfClass:NSString.class] || ![command isKindOfClass:NSString.class]) {
        return;
    }
    NSString *response = VibeExecuteDebugCommand(command);
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    LogInfo(@"Debug command handled: %@", command);
}

void VibeInstallDebugCommandHook(void) {
    static int token;
    notify_register_dispatch(kVibeDebugCommandNotification.UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        VibeHandleDebugCommandFile();
    });
}

#pragma mark Client side

int VibeDebugCommandClientMain(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [parts addObject:@(argv[i])];
        }
        if (parts.count == 0) {
            fprintf(stderr, "usage: Vibe --debug-cmd <command> [args...]\n");
            return 64;
        }
        NSString *commandId = NSUUID.UUID.UUIDString;
        NSDictionary *payload = @{
            @"id": commandId,
            @"command": [parts componentsJoinedByString:@" "],
        };
        // Same bundle ID + sandbox entitlements as the app, so NSTemporaryDirectory()
        // resolves to the same container tmp the app-side handler reads.
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (![data writeToFile:VibeDebugCommandPath() atomically:YES]) {
            fprintf(stderr, "vibe: cannot write %s\n", VibeDebugCommandPath().fileSystemRepresentation);
            return 1;
        }
        notify_post(kVibeDebugCommandNotification.UTF8String);

        NSString *responsePath = VibeDebugResponsePath(commandId);
        NSFileManager *fileManager = NSFileManager.defaultManager;
        for (int i = 0; i < 100; i++) { // 5s at 50ms
            usleep(50 * 1000);
            if ([fileManager fileExistsAtPath:responsePath]) {
                NSString *response = [NSString stringWithContentsOfFile:responsePath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:nil];
                [fileManager removeItemAtPath:responsePath error:nil];
                if (response.length) {
                    printf("%s\n", response.UTF8String);
                }
                return [response hasPrefix:@"ERROR"] ? 2 : 0;
            }
        }
        [fileManager removeItemAtPath:VibeDebugCommandPath() error:nil];
        fprintf(stderr, "vibe: no response after 5s — is a debug build of Vibe running?\n");
        return 1;
    }
}

#endif
