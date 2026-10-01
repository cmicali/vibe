//
//  MainPlayerController+Settings.m
//  Vibe
//

#import "MainPlayerController+Settings.h"
#import "ArtworkDisplayController.h"
#import "PlaylistController.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "MainWindow.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFileHandle.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioWaveformView.h"
#import "Fonts.h"
#import "MainMenuBuilder.h"
#import "PlaylistTableView.h"
#import "MainPlayerContentView.h"
#import "PitchControlPanel.h"
#import "TrackDisplayController.h"

@implementation MainPlayerController (Settings)

- (void)applyStoredFonts {
    [Fonts applyThemeFonts:AppSettings.sharedInstance.currentTheme];
}

- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects {
    [self applySettingsLiveEffects:effects updatingOutputModes:YES];
}

- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects updatingOutputModes:(BOOL)updatingOutputModes {
    NSAssert(NSThread.isMainThread, @"Settings live effects are main-thread only");
    AppSettings *settings = AppSettings.sharedInstance;

    if (effects & VibeSettingsLiveEffectAlwaysOnTop) {
        [self applyAlwaysOnTop];
    }
    if (effects & VibeSettingsLiveEffectWindowLock) {
        [self applyWindowLock];
    }
    if (effects & VibeSettingsLiveEffectTrafficLights) {
        [self applyTrafficLights];
    }
    if (effects & VibeSettingsLiveEffectAppIcon) {
        [self applyAppIcon];
    }
    if (effects & VibeSettingsLiveEffectTransportButtons) {
        [self.playerContentView applyThemedTransportButtons];
    }
    if (effects & VibeSettingsLiveEffectPitchRange) {
        [self applyPitchRange];
    }
    if (effects & VibeSettingsLiveEffectEndOfTrack) {
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectReopenLastPlaylist) {
        [self applyReopenLastPlaylist];
    }
    if (effects & VibeSettingsLiveEffectCrossfade) {
        self.audioPlayer.crossfadeMilliseconds = settings.effectiveCrossfadeMilliseconds;
    }
    if (effects & VibeSettingsLiveEffectDeclick) {
        self.audioPlayer.declick = settings.declick;
    }
    if (effects & VibeSettingsLiveEffectMP3Decoder) {
        AudioFileHandle.appleMPEGDecoder = settings.appleMPEGDecoder;
        // The parked next track was opened with the old decoder: reopen it.
        [self.audioPlayer prefetchTrack:nil];
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectVolume) {
        self.audioPlayer.volume = (float)settings.effectiveVolume;
        [self.playerContentView applyVolumeControl];
    }
    if (effects & VibeSettingsLiveEffectBitPerfect) {
        BOOL bitPerfect = settings.bitPerfectOutput;
        if (bitPerfect) {
            // No varispeed under the mode. The toggle pins the siblings for
            // the animation.
            self.audioPlayer.pitch = 0;
            _pitchPanel.pitch = 0;
            if (((MainWindow *)self.window).isPitchPanelShown) {
                [self togglePitchPanel:nil];
            }
            [self updateRateDependentUI];
            [self updateNowPlaying];
        }
    }
    if (effects & VibeSettingsLiveEffectUIUpdateRate) {
        [self syncUITimerRate];
    }
    // Reset changes appearance, style and colors together; settle their inputs
    // before either color refresh.
    if (effects & VibeSettingsLiveEffectWindowAppearance) {
        [self applyStoredAppearance];
    }
    if (effects & VibeSettingsLiveEffectWindowChrome) {
        [self applyWindowChrome];
    }
    if (effects & VibeSettingsLiveEffectFonts) {
        [self applyStoredFonts];
        // The re-style resets the title to base size; the refit must follow.
        [self.playerContentView applyThemedLabelFonts];
        [self.trackDisplay refitTitle];
    }
    if (effects & VibeSettingsLiveEffectPlaylistRowFills) {
        [self.playlistTableView enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
            rowView.needsDisplay = YES;
        }];
    }
    if (effects & VibeSettingsLiveEffectPlaylistBackground) {
        [self.playerContentView applyPlaylistBackground];
    }
    if (effects & VibeSettingsLiveEffectPlaylistAppearance) {
        [PlaylistTableView invalidateCellAttributes];
        [self.playerContentView applyPlaylistBackground];
        [self.playlistTableView applyThemedColumnVisibility];
        [self.playlistTableView reloadData];
    }
    if (effects & VibeSettingsLiveEffectWaveformStyle) {
        self.waveformView.waveformStyle = settings.currentTheme.waveformStyle;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
    }
    if (effects & VibeSettingsLiveEffectWaveformLevels) {
        [self.waveformView refreshWaveformLevels];
    }
    if (effects & VibeSettingsLiveEffectWindowTint) {
        [self refreshWindowTint];
    }
    if (effects & VibeSettingsLiveEffectTrackDisplay) {
        // Colors only, so a color drag never re-measures the title. The
        // guards compare content, so they reset for unchanged strings to
        // repaint.
        [self.playerContentView applyThemedLabelColors];
        [self->_artworkController refreshDefaultArtwork];
        [self.trackDisplay resetRenderGuards];
        [self updateUI];
    }
    if (effects & VibeSettingsLiveEffectFolderArt) {
        [self refreshFolderArt];
    }
    if (effects & VibeSettingsLiveEffectShortcuts) {
        [MainMenuBuilder applyShortcuts];
        VibeShortcut open = VibeShortcutEffective(kVibeMenuOpen, settings.shortcutOverrides);
        [self.playerContentView setOpenShortcut:open == kVibeShortcutNone
                ? nil : [MainMenuBuilder displayStringForShortcut:open]];
    }
    if (effects & VibeSettingsLiveEffectConvertMenu) {
        [MainMenuBuilder applyConvertMenuVisibility];
    }
    if (effects & (VibeSettingsLiveEffectBitPerfect | VibeSettingsLiveEffectFXControls)) {
        if (updatingOutputModes) {
            [self.audioPlayer setBitPerfectOutput:settings.bitPerfectOutput
                                 exclusiveOutput:settings.exclusiveOutput
                                        enableFX:settings.audioFXEnabled allowAnyDevice:settings.allowBitPerfectOnAnyDevice];
        }
        [self updateFXIndicators];
        [MainMenuBuilder applyFXMenuVisibility];
    }
}

@end
