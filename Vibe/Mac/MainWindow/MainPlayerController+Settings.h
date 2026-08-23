//
//  MainPlayerController+Settings.h
//  Vibe
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, VibeSettingsLiveEffect) {
    VibeSettingsLiveEffectAlwaysOnTop      = 1UL << 0,
    VibeSettingsLiveEffectPitchRange       = 1UL << 1,
    VibeSettingsLiveEffectEndOfTrack       = 1UL << 2,
    VibeSettingsLiveEffectCrossfade        = 1UL << 3,
    VibeSettingsLiveEffectUIUpdateRate     = 1UL << 4,
    VibeSettingsLiveEffectWindowAppearance = 1UL << 5,
    VibeSettingsLiveEffectWaveformStyle    = 1UL << 6,
    VibeSettingsLiveEffectWaveformTheme    = 1UL << 7,
    VibeSettingsLiveEffectWindowTint       = 1UL << 8,
    // showFileInfo, showRemainingTime, showBPM, showKey, keyNotation and
    // keyColorsEnabled share one display pass.
    VibeSettingsLiveEffectTrackDisplay     = 1UL << 9,
    VibeSettingsLiveEffectFolderArt        = 1UL << 10,
    VibeSettingsLiveEffectConvertMenu      = 1UL << 11,
    VibeSettingsLiveEffectFXControls       = 1UL << 12,
    VibeSettingsLiveEffectAll              = NSUIntegerMax,
};

@interface MainPlayerController (Settings)

// Applies the running-app half of settings that were already stored. Never
// writes settings or window geometry.
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects;

@end

NS_ASSUME_NONNULL_END
