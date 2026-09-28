//
//  DebugStateDump.m
//  Vibe
//
//  What the inspection verbs read: player and UI state, the view tree, menus.
//

#import "DebugInternal.h"
#import "PlatformColor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer+Devices.h"
#import "CoreAudioUtil.h"
#import "SettingsRules.h"

#if DEBUG

#pragma mark App side: command execution

static NSString *VibeDebugDisplayStateName(TrackDisplayState state) {
    switch (state) {
        case TrackDisplayStateTrack: return @"track";
        case TrackDisplayStateLoading: return @"loading";
        case TrackDisplayStateEmpty: return @"empty";
        case TrackDisplayStateLaunchGrace: return @"launch-grace";
        case TrackDisplayStateError: return @"error";
    }
    return @"unknown";
}

NSDictionary *VibeStateDictionary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;

    // The shared blocks, with mac-only fields added to "player" and
    // "playlist", plus ui, window and settings.
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(controller);
    NSMutableDictionary *bitPerfect = [player.bitPerfectReportDictionary mutableCopy];
    [bitPerfect addEntriesFromDictionary:player.outputDeviceDiagnosticSnapshot];
    NSInteger outputDeviceID = [bitPerfect[@"boundOutputDeviceId"] integerValue];
    NSString *outputDeviceUID = nil;
    [CoreAudioUtil readUID:&outputDeviceUID forDeviceID:(AudioDeviceID)outputDeviceID];
    [state[@"player"] addEntriesFromDictionary:@{
        @"pitch": @(player.pitch),
        @"volume": @(player.volume),
        @"maxPitch": @(player.maxPitch),
        @"playbackRate": @(1.0 + player.pitch / 100.0),
        @"lowKill": @(player.fx.lowKillEnabled),
        @"lowKillBoost": @(player.fx.lowKillBoostActive),
        @"reverbSend": @(player.fx.reverbSendEnabled),
        @"delaySend": @(player.fx.delaySendEnabled),
        @"shortDelaySend": @(player.fx.shortDelaySendEnabled),
        @"outputDeviceId": @(outputDeviceID),
        @"outputDeviceUID": outputDeviceUID ?: @"",
        @"requestedOutputDeviceId": @(player.currentlyRequestedAudioDeviceId),
        @"bitPerfect": bitPerfect,
        // noAudioHw is the flag asked; this is whether the player holds a
        // pump. They differ when no pump could attach and the output unit
        // opened anyway, which no other signal reveals.
        @"manualRendering": @(player.manualRenderingActive),
    }];
    // The table selection, not the playing row: what Remove from Playlist and
    // Play Selected Track act on. selectedRow is the topmost or -1;
    // selectedRows, from the controller's own primitive, is the group-gesture
    // oracle.
    NSMutableArray<NSNumber *> *selectedRows = [NSMutableArray array];
    [controller.playlistController.selectedRows
            enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [selectedRows addObject:@(row)];
    }];
    [state[@"playlist"] addEntriesFromDictionary:@{
        @"selectedRow": @(controller.playlistController.selectedRow),
        @"selectedRows": selectedRows,
    }];

    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    [state addEntriesFromDictionary:@{
        @"ui": @{
            @"title": controller.trackDisplay.titleTextField.stringValue ?: @"",
            @"artist": controller.trackDisplay.artistTextField.stringValue ?: @"",
            @"currentTime": controller.trackDisplay.currentTimeTextField.stringValue ?: @"",
            @"totalTime": controller.trackDisplay.totalTimeTextField.stringValue ?: @"",
            @"fileMetadata": controller.trackDisplay.fileMetadataTextField.stringValue ?: @"",
            @"timeLabelsHidden": @(controller.trackDisplay.currentTimeTextField.isHidden),
            @"playButtonEnabled": @(controller.playButton.isEnabled),
            // The resting color the transport backdrop's light/dark sample
            // picked: the only outside view of that sample.
            @"playButtonColor": VibeHexStringFromColor(controller.playButton.symbolNormalColor) ?: @"",
            @"nextButtonEnabled": @(controller.nextButton.isEnabled),
            @"pitchFader": @(controller.pitchPanel.pitch),
            @"volumeSlider": @{@"value": @(controller.playerContentView.volumeSlider.doubleValue),
                               @"hidden": @(controller.playerContentView.volumeControlView.isHidden),
                               @"alpha": @(controller.playerContentView.volumeControlView.alphaValue),
                               @"dragging": @(controller.playerContentView.volumeDragging),
                               @"fill": VibeHexStringFromColor(controller.playerContentView.volumeSlider.trackFillColor) ?: @""},
            @"converting": @(controller.fileConverter.isConverting),
            @"convertSweep": @(controller.trackDisplay.convertSweepFraction),
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
            @"uiUpdateHz": @(controller.debugUIUpdateHz),
            @"displayState": VibeDebugDisplayStateName(controller.displayState),
        },
        @"window": @{
            @"frame": NSStringFromRect(window.frame),
            @"movable": @(window.isMovable),
            @"playlistShown": @(window.isPlaylistShown),
            @"pitchPanelShown": @(window.isPitchPanelShown),
            @"keyWindow": @(window.isKeyWindow),
        },
        @"settings": @{
            @"pitchRange": @(AppSettings.sharedInstance.pitchRange),
            @"playlistShown": @(AppSettings.sharedInstance.isPlaylistShown),
            @"pitchPanelShown": @(AppSettings.sharedInstance.isPitchPanelShown),
            @"waveformStyle": theme.waveformStyle,
            @"windowAppearance": AppSettings.sharedInstance.windowAppearanceStyle.length
                    ? AppSettings.sharedInstance.windowAppearanceStyle : @"system",
            @"waveformTheme": theme.waveformTheme,
            @"waveformDragBehavior": AppSettings.sharedInstance.waveformDragBehavior,
            @"artworkDragAction": AppSettings.sharedInstance.artworkDragAction,
            @"outputDeviceName": AppSettings.sharedInstance.audioOutputDeviceName ?: @"",
            @"outputDeviceUID": AppSettings.sharedInstance.audioOutputDeviceUID ?: @"",
            // The saved device's remembered modes, not the player's report.
            @"bitPerfectOutput": @(AppSettings.sharedInstance.bitPerfectOutput),
            @"allowBitPerfectOnAnyDevice": @(AppSettings.sharedInstance.allowBitPerfectOnAnyDevice),
            @"appleMPEGDecoder": @(AppSettings.sharedInstance.appleMPEGDecoder),
            @"exclusiveOutput": @(AppSettings.sharedInstance.exclusiveOutput),
            @"declick": @(AppSettings.sharedInstance.declick),
            @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
            // The stored choice; player.crossfadeMilliseconds is the effective one.
            @"crossfadeMilliseconds": @(AppSettings.sharedInstance.crossfadeMilliseconds),
            @"reopenLastPlaylist": @(AppSettings.sharedInstance.reopenLastPlaylist),
            @"convertEnabled": @(AppSettings.sharedInstance.convertEnabled),
            @"showBPM": @(theme.showBPM),
            @"showKey": @(theme.showKey),
            @"showTrafficLights": @(AppSettings.sharedInstance.showTrafficLights),
            @"waveformNormalize": @(AppSettings.sharedInstance.waveformNormalize),
            @"waveformGainDB": @(AppSettings.sharedInstance.waveformGainDB),
            @"windowTint": theme.windowTint,
            @"playlistTint": theme.playlistTint,
            @"volumeControl": @(AppSettings.sharedInstance.volumeControl),
            @"volumeTint": theme.volumeTint,
            @"showVolumeLabels": @(theme.showVolumeLabels),
            @"volumeLocation": theme.volumeLocation,
            @"deleteOriginalAfterConvert": @(AppSettings.sharedInstance.deleteOriginalAfterConvert),
            @"analyzeBPM": @(AppSettings.sharedInstance.analyzeBPM),
            @"analyzeKey": @(AppSettings.sharedInstance.analyzeKey),
            @"keyNotation": theme.keyNotation,
            @"keyColors": @(theme.keyColorsEnabled),
            @"uiUpdateHzCap": @(AppSettings.sharedInstance.uiUpdateHzCap),
            @"folderArt": @(AppSettings.sharedInstance.useFolderArt),
            @"folderOpenSort": VibeFolderOpenSortIdentifier(AppSettings.sharedInstance.folderOpenSort),
            @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
            @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count),
            @"windowCornerRadius": @(theme.resolvedWindowCornerRadius),
            @"customCornerRadius": @(theme.customCornerRadius),
            @"dockIcon": theme.dockIcon,
            @"appIconShape": @(theme.appIconShape),
            @"appIcon": [theme imageReferenceForKey:kVibeThemeImageAppIcon],
            @"buttonGradient": theme.buttonGradient,
            @"playlistNumberColorEnabled": @([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistNumber]),
            @"playlistTitleColorEnabled": @([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistTitle]),
            @"playlistArtistColorEnabled": @([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistArtist]),
            @"playlistDurationColorEnabled": @([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistDuration]),
            @"playlistButtonGlyph": theme.playlistButtonGlyph,
            @"playButtonGlyph": theme.playButtonGlyph,
            @"pauseButtonGlyph": theme.pauseButtonGlyph,
            @"nextButtonGlyph": theme.nextButtonGlyph,
            @"windowBackgroundStyle": theme.windowBackgroundStyle,
            @"playlistBackgroundStyle": theme.playlistBackgroundStyle,
            @"titleFont": [NSString stringWithFormat:@"%@ %g",
                    theme.titleFontFace,
                    theme.titleFontSize],
            @"infoFont": [NSString stringWithFormat:@"%@ %g",
                    theme.infoFontFace,
                    theme.infoFontSize],
            @"playlistFont": [NSString stringWithFormat:@"%@ %g",
                    theme.playlistFontFace,
                    theme.playlistFontSize],
        },
    }];
    return state;
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

NSString *VibeViewTreeDump(void) {
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

NSArray *VibeMenuArray(NSMenu *menu) {
    // Delegate-built menus (Output, Open Recent, Themes) populate only when
    // displayed, and [menu update] alone does not call menuNeedsUpdate:.
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
        [menu.delegate menuNeedsUpdate:menu];
    }
    // Validates as opening the menu would, so enabled and state are live.
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
        // Still in itemArray but not on screen, e.g. Convert with conversion
        // disabled in Settings.
        if (item.isHidden) {
            node[@"hidden"] = @YES;
        }
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

NSString *VibeClickMenuItem(NSString *name) {
    NSMenuItem *item = VibeFindMenuItem(NSApp.mainMenu, name);
    if (!item) {
        return VibeErrorJSON(@"no menu item with identifier or title '%@' (run `dump_menu` to list)", name);
    }
    [item.menu update]; // same validation pass opening the menu would run
    if (!item.isEnabled) {
        return VibeErrorJSON(@"menu item '%@' is disabled", item.title);
    }
    // TRAP: AppKit gives a submenu parent submenuAction: even when it was built
    // with action:NULL, so the nil-action check below misses it, and sending
    // that action to a responder that does not implement it aborts the app.
    if (item.hasSubmenu) {
        return VibeErrorJSON(@"menu item '%@' opens a submenu; click one of its items",
                             item.title);
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

// A compact reply for the action verbs, enough to assert on without a
// dump_state round trip. Read synchronously after async transport work
// starts, so it can be a beat behind.
NSDictionary *VibeActionSummaryDictionary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    MainWindow *window = (MainWindow *)controller.window;
    return @{
        @"ok": @YES,
        @"state": VibeDebugPlayerStateName(player),
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
    };
}

#endif
