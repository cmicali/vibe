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
    VibeSettingsLiveEffectTrafficLights    = 1UL << 13,
    // The themed window shape and background: the corner radius at every
    // consumer, and the solid-background cover over the glass.
    VibeSettingsLiveEffectWindowChrome     = 1UL << 14,
    // The five themed font slots: push the theme's choice into Fonts, then
    // re-resolve every label that holds a slot font.
    VibeSettingsLiveEffectFonts            = 1UL << 15,
    // The playlist's themed colors and font: cell attributes rebuild, rows
    // redraw, and the background under the rows re-resolves (glass lift or
    // solid cover — the tint wash above it rides WindowTint).
    VibeSettingsLiveEffectPlaylistAppearance = 1UL << 16,
    // Just the playlist row fills, redrawn in place — PlaylistRowView reads
    // its themed fill per draw, so a playing/selected-row color edit needs no
    // cell rebuild. The lighter sibling of PlaylistAppearance for live drags.
    VibeSettingsLiveEffectPlaylistRowFills = 1UL << 17,
    // Just the background under the rows (glass lift or solid cover) — one
    // layer color the cells never read, so a background color drag skips the
    // cell rebuild and reload. The other lighter sibling for live drags.
    VibeSettingsLiveEffectPlaylistBackground = 1UL << 18,
    // Everything applying a whole theme moves at once. WindowAppearance is
    // included because a single-mode theme demands the pinned dark
    // appearance (AppTheme.requiredWindowAppearance) even though the
    // appearance SETTING stays a common one; TrafficLights stays outside.
    VibeSettingsLiveEffectThemeApply       = VibeSettingsLiveEffectWindowAppearance
                                           | VibeSettingsLiveEffectWaveformStyle
                                           | VibeSettingsLiveEffectWaveformTheme
                                           | VibeSettingsLiveEffectWindowTint
                                           | VibeSettingsLiveEffectWindowChrome
                                           | VibeSettingsLiveEffectFonts
                                           | VibeSettingsLiveEffectPlaylistAppearance
                                           | VibeSettingsLiveEffectTrackDisplay,
    VibeSettingsLiveEffectAll              = NSUIntegerMax,
};

@interface MainPlayerController (Settings)

// Pushes the theme's font choice into Fonts (Util may not read a setting).
// buildContentInWindow: runs it before any label exists; the Fonts effect
// re-runs it live.
- (void)applyStoredFonts;

// Applies the running-app half of settings that were already stored. Never
// writes settings or window geometry.
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects;

@end

NS_ASSUME_NONNULL_END
