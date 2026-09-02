//
//  DebugStateDump.m
//  Vibe
//
//  What the inspection verbs read: player and UI state, the view tree, menus.
//

#import "DebugInternal.h"
#import "AppSettings.h"
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

    // The player, currentTrack and playlist blocks are shared with iOS; this
    // side extends "player" with the fields only the mac has, and adds the
    // three blocks below.
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(controller);
    [state[@"player"] addEntriesFromDictionary:@{
        @"pitch": @(player.pitch),
        @"maxPitch": @(player.maxPitch),
        @"playbackRate": @(1.0 + player.pitch / 100.0),
        @"lowKill": @(player.fx.lowKillEnabled),
        @"lowKillBoost": @(player.fx.lowKillBoostActive),
        @"reverbSend": @(player.fx.reverbSendEnabled),
        @"delaySend": @(player.fx.delaySendEnabled),
        @"shortDelaySend": @(player.fx.shortDelaySendEnabled),
        @"delayTapBPM": @(player.fx.delayTapBPM),
        @"outputDeviceId": @(player.currentlyActiveAudioDeviceId),
        // The flag asked; this is what actually happened. They differ when
        // enableManualRenderingMode fails and the output device opens
        // anyway — which no other signal would reveal.
        @"manualRendering": @(player.manualRenderingActive),
    }];
    // The keyboard selection, which is not the playing row: only this platform
    // has one, and it is what Remove from Playlist and Play Selected Track act
    // on. selectedRow is the topmost selected row or -1; selectedRows is every
    // selected row, the group-gesture oracle — read from the controller's own
    // selection primitive, not reconstructed.
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
            @"nextButtonEnabled": @(controller.nextButton.isEnabled),
            @"pitchFader": @(controller.pitchPanel.pitch),
            @"converting": @(controller.fileConverter.isConverting),
            @"convertSweep": @(controller.trackDisplay.convertSweepFraction),
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
            @"uiUpdateHz": @(controller.debugUIUpdateHz),
            @"displayState": VibeDebugDisplayStateName(controller.displayState),
        },
        @"window": @{
            @"frame": NSStringFromRect(window.frame),
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
            @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
            @"convertEnabled": @(AppSettings.sharedInstance.convertEnabled),
            @"showBPM": @(theme.showBPM),
            @"showKey": @(theme.showKey),
            @"showTrafficLights": @(AppSettings.sharedInstance.showTrafficLights),
            @"windowTint": theme.windowTint,
            @"playlistTint": theme.playlistTint,
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
            @"windowCornerRadius": @(theme.windowCornerRadius),
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
        // A hidden item is still in itemArray but not on screen — the Convert
        // menu with Settings > Convert > Enabled off.
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
        return VibeErrorJSON(@"no menu item with identifier or title '%@' (run `menu` to list)", name);
    }
    [item.menu update]; // same validation pass opening the menu would run
    if (!item.isEnabled) {
        return VibeErrorJSON(@"menu item '%@' is disabled", item.title);
    }
    // TRAP: a submenu parent is built with action:NULL, but AppKit assigns it
    // submenuAction: as soon as it gets a submenu — so the nil-action check
    // below does NOT catch it, and sending that action reaches a responder
    // which does not implement it and aborts the app. The random clicker finds
    // every top-level submenu, so this read as an app crash in stress runs.
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

// A compact result for the action commands: enough to assert on without a
// second `state` round-trip. Transport actions kick off async engine work, so
// the state here can be a beat behind, since it is read synchronously after
// the call.
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

NSString *VibeActionSummary(MainPlayerController *controller) {
    return VibeJSONString(VibeActionSummaryDictionary(controller));
}

#endif
