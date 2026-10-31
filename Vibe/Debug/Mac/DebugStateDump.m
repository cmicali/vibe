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
#import "AppThemeInternal.h"
#import "AudioPlayer+BitPerfect.h"
#import "AudioPlayer+Devices.h"
#import "CoreAudioUtil.h"
#import "SettingsRules.h"
#import "DrawnControls.h"
#import "VolumeControlView.h"
#import "AppDelegate+Debug.h"

#if DEBUG

#pragma mark App side: command execution

static NSString *VibeDebugDisplayStateName(TrackDisplayState state) {
    switch (state) {
        case TrackDisplayStateTrack: return @"track";
        case TrackDisplayStateLoading: return @"loading";
        case TrackDisplayStateEmpty: return @"empty";
        case TrackDisplayStateLaunchGrace: return @"launch-grace";
        case TrackDisplayStateError: return @"error";
        case TrackDisplayStateNotice: return @"notice";
    }
    return @"unknown";
}

// Open URL's window, found by what its controls are: the one editable field,
// and each button by its action.
static NSView *VibeOpenURLControl(NSView *view, BOOL (^match)(NSView *)) {
    if (match(view)) {
        return view;
    }
    for (NSView *subview in view.subviews) {
        NSView *found = VibeOpenURLControl(subview, match);
        if (found) {
            return found;
        }
    }
    return nil;
}

static NSTextField *VibeOpenURLField(NSWindow *window) {
    return (NSTextField *)VibeOpenURLControl(window.contentView, ^BOOL(NSView *view) {
        return [view isKindOfClass:NSTextField.class] && ((NSTextField *)view).isEditable;
    });
}

static NSButton *VibeOpenURLButton(NSWindow *window, NSString *action) {
    return (NSButton *)VibeOpenURLControl(window.contentView, ^BOOL(NSView *view) {
        return [view isKindOfClass:NSButton.class] && ((NSButton *)view).action == NSSelectorFromString(action);
    });
}

NSDictionary *VibeOpenURLWindowState(void) {
    AppDelegate *delegate = (AppDelegate *)NSApp.delegate;
    NSWindow *window = delegate.debugOpenLinkWindow;
    if (!window) {
        return @{@"shown": @NO};
    }
    return @{
        @"shown": @YES,
        @"text": VibeOpenURLField(window).stringValue ?: @"",
        @"resolving": @(delegate.debugOpenLinkResolving),
        @"key": @(window.isKeyWindow),
        @"openEnabled": @(VibeOpenURLButton(window, @"confirmOpenLink:").isEnabled),
    };
}

// Types through the field editor, so the field's own change handling runs.
// The buttons are clicked, and close is the title bar's close button.
NSString *VibeDriveOpenURLWindow(NSArray<NSString *> *tokens) {
    NSWindow *window = ((AppDelegate *)NSApp.delegate).debugOpenLinkWindow;
    if (!window) {
        return VibeErrorJSON(@"the Open URL window is not shown");
    }
    NSString *argument = VibeRestArgument(tokens);
    if (tokens.count == 2 && ([argument isEqualToString:@"open"] || [argument isEqualToString:@"cancel"])) {
        NSButton *button = VibeOpenURLButton(window, [argument isEqualToString:@"open"] ? @"confirmOpenLink:" : @"cancelOpenLink:");
        if (!button.isEnabled) {
            return VibeErrorJSON(@"%@ is disabled", argument);
        }
        [button performClick:nil];
    }
    else if (tokens.count == 2 && [argument isEqualToString:@"close"]) {
        [window performClose:nil];
    }
    else {
        NSTextField *field = VibeOpenURLField(window);
        if (!field.isEnabled) {
            return VibeErrorJSON(@"the field is disabled");
        }
        [window makeFirstResponder:field];
        NSTextView *editor = (NSTextView *)field.currentEditor;
        [editor selectAll:nil];
        [editor insertText:argument replacementRange:editor.selectedRange];
    }
    NSMutableDictionary *reply = [VibeOpenURLWindowState() mutableCopy];
    reply[@"ok"] = @YES;
    return VibeJSONString(reply);
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
            @"volumeSlider": @{@"value": @(controller.playerContentView.volumeControlView.slider.doubleValue),
                               @"hidden": @(controller.playerContentView.volumeControlView.isHidden),
                               @"alpha": @(controller.playerContentView.volumeControlView.alphaValue),
                               @"dragging": @(controller.playerContentView.volumeDragging),
                               @"fill": VibeHexStringFromColor(controller.playerContentView.volumeControlView.slider.trackFillColor) ?: @"",
                               @"knob": VibeHexStringFromColor(controller.playerContentView.volumeControlView.slider.knobColor) ?: @""},
            @"converting": @(controller.fileConverter.isConverting),
            @"convertSweep": @(controller.trackDisplay.convertSweepFraction),
            @"waveformLoading": @(controller.trackDisplay.waveformLoadingIndicatorShown),
            @"notice": controller.noticeStatus ?: @"",
            @"bufferingShown": @(controller.audioPlayer.bufferingNoticeShown),
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
            @"uiUpdateHz": @(controller.debugUIUpdateHz),
            @"displayState": VibeDebugDisplayStateName(controller.displayState),
            @"headerState": VibeDebugDisplayStateName(controller.headerState),
            @"openURLWindow": VibeOpenURLWindowState(),
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
            @"waveformShadeOverlaps": @(theme.waveformShadeOverlaps),
            @"waveformSpectrumPalette": theme.waveformSpectrumPalette,
            @"waveformSpectrumColoring": theme.waveformSpectrumColoring,
            @"waveformPlayheadLine": @(theme.waveformPlayheadLine),
            @"waveformCentered": @(theme.waveformCentered),
            @"waveformDragBehavior": AppSettings.sharedInstance.waveformDragBehavior,
            @"artworkDragAction": AppSettings.sharedInstance.artworkDragAction,
            @"outputDeviceName": AppSettings.sharedInstance.audioOutputDeviceName ?: @"",
            @"outputDeviceUID": AppSettings.sharedInstance.audioOutputDeviceUID ?: @"",
            // The saved device's remembered modes, not the player's report.
            @"bitPerfectOutput": @(AppSettings.sharedInstance.bitPerfectOutput),
            @"allowBitPerfectOnAnyDevice": @(AppSettings.sharedInstance.allowBitPerfectOnAnyDevice),
            @"exclusiveOutput": @(AppSettings.sharedInstance.exclusiveOutput),
            @"declick": @(AppSettings.sharedInstance.declick),
            @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
            @"repeatMode": VibeRepeatModeIdentifier(AppSettings.sharedInstance.repeatMode),
            @"shuffleEnabled": @(AppSettings.sharedInstance.shuffleEnabled),
            // The stored choice; player.crossfadeMilliseconds is the effective one.
            @"crossfadeMilliseconds": @(AppSettings.sharedInstance.crossfadeMilliseconds),
            @"reopenLastPlaylist": @(AppSettings.sharedInstance.reopenLastPlaylist),
            @"convertEnabled": @(AppSettings.sharedInstance.convertEnabled),
            @"showBPM": @(AppSettings.sharedInstance.showBPM),
            @"showKey": @(AppSettings.sharedInstance.showKey),
            @"showTrafficLights": @(AppSettings.sharedInstance.showTrafficLights),
            @"showTimeLabels": @(AppSettings.sharedInstance.showTimeLabels),
            @"showRemainingTime": @(AppSettings.sharedInstance.showRemainingTime),
            @"showStatusIcons": @(AppSettings.sharedInstance.showStatusIcons),
            @"showFileInfo": @(AppSettings.sharedInstance.showFileInfo),
            @"showPlaylistNumberColumn": @(AppSettings.sharedInstance.showPlaylistNumberColumn),
            @"showPlaylistArtworkColumn": @(AppSettings.sharedInstance.showPlaylistArtworkColumn),
            @"showPlaylistDurationColumn": @(AppSettings.sharedInstance.showPlaylistDurationColumn),
            @"waveformNormalize": @(AppSettings.sharedInstance.waveformNormalize),
            @"waveformGainDB": @(AppSettings.sharedInstance.waveformGainDB),
            @"windowTint": theme.windowTint,
            @"playlistTint": theme.playlistTint,
            @"volumeControl": @(AppSettings.sharedInstance.volumeControl),
            @"volumeBar": theme.volumeBar,
            @"volumeKnob": theme.volumeKnob,
            @"showVolumeLabels": @(AppSettings.sharedInstance.showVolumeLabels),
            @"volumeLocation": AppSettings.sharedInstance.volumeLocation,
            @"volumeVisibility": AppSettings.sharedInstance.volumeVisibility,
            @"deleteOriginalAfterConvert": @(AppSettings.sharedInstance.deleteOriginalAfterConvert),
            @"analyzeBPM": @(AppSettings.sharedInstance.analyzeBPM),
            @"analyzeKey": @(AppSettings.sharedInstance.analyzeKey),
            @"keyNotation": AppSettings.sharedInstance.keyNotation,
            @"keyColors": @(AppSettings.sharedInstance.keyColorsEnabled),
            @"uiUpdateHzCap": @(AppSettings.sharedInstance.uiUpdateHzCap),
            @"folderArt": @(AppSettings.sharedInstance.useFolderArt),
            @"folderOpenSort": VibeFolderOpenSortIdentifier(AppSettings.sharedInstance.folderOpenSort),
            @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
            @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count),
            @"windowCornerRadius": @(theme.resolvedWindowCornerRadius),
            @"customCornerRadius": @(theme.customCornerRadius),
            @"dockIcon": AppSettings.sharedInstance.dockIcon,
            @"appIconShape": @(theme.appIconShape),
            @"appIcon": [theme imageReferenceForKey:kVibeThemeImageAppIcon],
            @"buttonGradient": theme.buttonGradient,
            @"playlistButtonGlyph": theme.playlistButtonGlyph,
            @"playButtonGlyph": theme.playButtonGlyph,
            @"pauseButtonGlyph": theme.pauseButtonGlyph,
            @"nextButtonGlyph": theme.nextButtonGlyph,
            @"windowBackgroundStyle": theme.windowBackgroundStyle,
            @"playlistBackgroundStyle": theme.playlistBackgroundStyle,
            @"titleFont": [NSString stringWithFormat:@"%@ %g",
                    [theme fontFaceForSlot:VibeFontSlotTitle],
                    [theme fontSizeForSlot:VibeFontSlotTitle]],
            @"infoFont": [NSString stringWithFormat:@"%@ %g",
                    [theme fontFaceForSlot:VibeFontSlotInfo],
                    [theme fontSizeForSlot:VibeFontSlotInfo]],
            @"playlistFont": [NSString stringWithFormat:@"%@ %g",
                    [theme fontFaceForSlot:VibeFontSlotPlaylist],
                    [theme fontSizeForSlot:VibeFontSlotPlaylist]],
        },
    }];
    // Every switched playlist pair's switch, under its base.
    NSMutableDictionary *settings = [state[@"settings"] mutableCopy];
    for (NSString *base in VibeThemePlaylistColorFallbackBases()) {
        settings[[base stringByAppendingString:@"Enabled"]] = @([theme playlistColorEnabledForBase:base]);
    }
    state[@"settings"] = settings;
    return state;
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
