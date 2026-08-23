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
#import "MainMenuBuilder.h"

@implementation MainPlayerController (Settings)

- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects {
    NSAssert(NSThread.isMainThread, @"Settings live effects are main-thread only");
    AppSettings *settings = AppSettings.sharedInstance;

    if (effects & VibeSettingsLiveEffectAlwaysOnTop) {
        [self applyAlwaysOnTop];
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
    if (effects & VibeSettingsLiveEffectWaveformStyle) {
        self.waveformView.waveformStyle = settings.waveformStyle;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
    }
    if (effects & VibeSettingsLiveEffectWindowTint) {
        [self refreshWindowTint];
    }
    if (effects & VibeSettingsLiveEffectTrackDisplay) {
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
