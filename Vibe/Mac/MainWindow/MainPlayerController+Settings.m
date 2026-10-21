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
#import "MainPlayerController+Playlist.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "MainWindow.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioTrack.h"
#import "AudioPlayer.h"
#import "AudioPlayer+BitPerfect.h"
#import "WaveformView.h"
#import "Fonts+Theme.h"
#import "MainMenuBuilder.h"
#import "PlaylistTableView.h"
#import "MainPlayerContentView.h"
#import "PitchControlPanel.h"
#import "TrackDisplayController.h"
#import "AudioWaveformCache.h"

@implementation MainPlayerController (Settings)

- (void)applyStoredFonts {
    [Fonts applyThemeFonts:AppSettings.sharedInstance.currentTheme];
}

// The style last: its set is the one draw. The theme's style, never the
// loose waveformStyle key, which theme migration consumed on macOS.
- (void)applyWaveformSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    WaveformView *view = self.waveformView;
    view.barDensity = theme.waveformBarDensity;
    view.barWidthScale = theme.waveformBarWidth;
    view.centered = theme.waveformCentered;
    view.normalizesLevels = settings.waveformNormalize;
    view.gainDB = (float)settings.waveformGainDB;
    view.dragSeeks = [settings.waveformDragBehavior isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK];
    view.waveformStyle = theme.waveformStyle;
}

- (VibeShortcutAssignment)assignShortcut:(VibeShortcut)shortcut toCommand:(NSString *)identifier
                                   loser:(NSString **)loser {
    unichar character = 0;
    if (shortcut != kVibeShortcutNone) {
        unsigned short keyCode = VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut));
        NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
        character = [MainMenuBuilder characterForKeyCode:keyCode modifiers:modifiers];
        if (VibeShortcutIsReserved(keyCode, character, modifiers)) {
            return VibeShortcutAssignmentReserved;
        }
        if (![MainMenuBuilder labelForKeyCode:keyCode modifiers:modifiers]) {
            return VibeShortcutAssignmentUnusable;
        }
    }
    AppSettings *settings = AppSettings.sharedInstance;
    settings.shortcutOverrides = VibeShortcutOverridesByAssigning(settings.shortcutOverrides, identifier,
                                                                  shortcut, character, loser);
    [self applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
    return VibeShortcutAssignmentStored;
}

- (void)resetShortcuts {
    [self setShortcutOverrides:@{}];
}

- (void)setShortcutOverrides:(NSDictionary<NSString *, NSNumber *> *)overrides {
    AppSettings.sharedInstance.shortcutOverrides = overrides;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
}

- (void)applyOpenShortcutHint {
    VibeShortcut open = VibeShortcutEffective(kVibeMenuOpen, AppSettings.sharedInstance.shortcutOverrides);
    [self.playerContentView setOpenShortcut:open == kVibeShortcutNone
            ? nil : [MainMenuBuilder displayStringForShortcut:open]];
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
    if (effects & VibeSettingsLiveEffectPlaylistRowColors) {
        [self.playlistTableView refreshRowColors];
    }
    if (effects & VibeSettingsLiveEffectPlaylistBackground) {
        [self.playerContentView applyPlaylistBackground];
    }
    if (effects & VibeSettingsLiveEffectPlaylistAppearance) {
        // The reload keeps the row views, so their fills must redraw too.
        [self.playlistTableView refreshRowColors];
        [self.playerContentView applyPlaylistBackground];
        [self.playlistTableView applyColumnVisibility];
        [self.playlistController reloadAllTracks];
    }
    if (effects & (VibeSettingsLiveEffectWaveformStyle | VibeSettingsLiveEffectWaveformLevels
                   | VibeSettingsLiveEffectWaveformDrag)) {
        [self applyWaveformSettings];
    }
    if (effects & (VibeSettingsLiveEffectWaveformStyle | VibeSettingsLiveEffectTrackAnalysis)) {
        // The track on screen was likely decoded without what is now asked
        // for (the bands, a tempo, a key); its entry misses and decodes again.
        VibeWaveformAnalysis wanted = self.waveformCache.analysisProvider();
        AudioTrack *track = self.playlistController.currentTrack;
        if (!VibeWaveformAnalysisCovers(_waveformAnalysisWanted, wanted) && track && [self displayState] == TrackDisplayStateTrack) {
            [self.waveformCache loadWaveformForTrack:track];
        }
        _waveformAnalysisWanted = wanted;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
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
        [self applyOpenShortcutHint];
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
