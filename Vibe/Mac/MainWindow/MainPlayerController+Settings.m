//
//  MainPlayerController+Settings.m
//  Vibe
//

#import "MainPlayerController+Settings.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "AppSettings.h"
#import "AudioPlayer.h"
#import "AudioWaveformView.h"
#import "Fonts.h"
#import "MainMenuBuilder.h"
#import "PlaylistTableView.h"
#import "MainPlayerContentView.h"
#import "TrackDisplayController.h"

@implementation MainPlayerController (Settings)

// The theme's font choice, pushed into Fonts — which may not read a setting
// itself. Runs before label construction at launch and from the Fonts effect.
- (void)applyStoredFonts {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    [Fonts applyThemeFonts:theme.mainFontFace mainSize:theme.mainFontSize
                  infoFace:theme.infoFontFace infoSize:theme.infoFontSize
              playlistFace:theme.playlistFontFace playlistSize:theme.playlistFontSize];
}

- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects {
    NSAssert(NSThread.isMainThread, @"Settings live effects are main-thread only");
    AppSettings *settings = AppSettings.sharedInstance;

    if (effects & VibeSettingsLiveEffectAlwaysOnTop) {
        [self applyAlwaysOnTop];
    }
    if (effects & VibeSettingsLiveEffectTrafficLights) {
        [self applyTrafficLights];
    }
    if (effects & VibeSettingsLiveEffectPitchRange) {
        [self applyPitchRange];
    }
    if (effects & VibeSettingsLiveEffectEndOfTrack) {
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectCrossfade) {
        self.audioPlayer.crossfadeMilliseconds = settings.crossfadeMilliseconds;
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
    }
    // Once for either bit — both re-style the same labels — before the refit,
    // which must shrink the freshly styled title font, and before TrackDisplay's
    // updateUI repaints.
    if (effects & (VibeSettingsLiveEffectFonts | VibeSettingsLiveEffectTrackDisplay)) {
        [self.playerContentView applyThemedTextStyle];
    }
    if (effects & VibeSettingsLiveEffectFonts) {
        [self.trackDisplay refitTitle];
    }
    if (effects & VibeSettingsLiveEffectPlaylistAppearance) {
        [PlaylistTableView invalidateCellAttributes];
        [self.playerContentView applyPlaylistBackground];
        [self.playlistTableView reloadData];
    }
    if (effects & VibeSettingsLiveEffectWaveformStyle) {
        self.waveformView.waveformStyle = settings.currentTheme.waveformStyle;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
    }
    if (effects & VibeSettingsLiveEffectWindowTint) {
        [self refreshWindowTint];
    }
    if (effects & VibeSettingsLiveEffectTrackDisplay) {
        // Label colors ride this effect too (the shared re-style above); drop
        // the content guards so unchanged strings still repaint.
        [self.trackDisplay resetRenderGuards];
        [self updateUI];
    }
    if (effects & VibeSettingsLiveEffectFolderArt) {
        [self refreshFolderArt];
    }
    if (effects & VibeSettingsLiveEffectConvertMenu) {
        [MainMenuBuilder applyConvertMenuVisibility];
    }
    if (effects & VibeSettingsLiveEffectFXControls) {
        if (!settings.audioFXEnabled) {
            self.lowKillBoostActive = NO;
            self.lowKillActive = NO;
            self.reverbSendActive = NO;
            self.delaySendActive = NO;
            self.shortDelaySendActive = NO;
        }
        [MainMenuBuilder applyFXMenuVisibility];
    }
}

@end
