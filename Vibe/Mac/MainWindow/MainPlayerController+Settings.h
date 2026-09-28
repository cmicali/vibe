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
    // Readout visibility, showRemainingTime, showBPM, showKey, keyNotation and
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
    // Row fills only: PlaylistRowView reads its fill per draw, so a live drag
    // skips the cell rebuild.
    VibeSettingsLiveEffectPlaylistRowFills = 1UL << 17,
    // The background under the rows only, a layer color the cells never read.
    VibeSettingsLiveEffectPlaylistBackground = 1UL << 18,
    // Normalize and gain: the renderer refills its morph target, so the bars
    // ease under a drag.
    VibeSettingsLiveEffectWaveformLevels   = 1UL << 19,
    // Off deletes the container mirror.
    VibeSettingsLiveEffectReopenLastPlaylist = 1UL << 20,
    // The theme's app icon, then the Dock tile re-decided.
    VibeSettingsLiveEffectAppIcon          = 1UL << 21,
    // The transport buttons' visibility, glyph or image, color and gradient.
    VibeSettingsLiveEffectTransportButtons = 1UL << 22,
    // Pushes bit-perfect and exclusive output; bit-perfect on zeroes the
    // pitch and hides the fader. A bitPerfectOutput write requests
    // BitPerfectApply instead.
    VibeSettingsLiveEffectBitPerfect       = 1UL << 23,
    VibeSettingsLiveEffectDeclick          = 1UL << 24,
    VibeSettingsLiveEffectWindowLock       = 1UL << 25, // not theme state
    // Pushes effectiveVolume to the player and shows or hides the slider.
    VibeSettingsLiveEffectVolume           = 1UL << 26,
    // WindowAppearance is included because a single-mode theme pins the
    // window dark (AppTheme.requiredWindowAppearance).
    VibeSettingsLiveEffectThemeApply       = VibeSettingsLiveEffectWindowAppearance
                                           | VibeSettingsLiveEffectWaveformStyle
                                           | VibeSettingsLiveEffectWaveformTheme
                                           | VibeSettingsLiveEffectWindowTint
                                           | VibeSettingsLiveEffectWindowChrome
                                           | VibeSettingsLiveEffectFonts
                                           | VibeSettingsLiveEffectPlaylistAppearance
                                           | VibeSettingsLiveEffectTrackDisplay
                                           | VibeSettingsLiveEffectAppIcon
                                           | VibeSettingsLiveEffectTransportButtons,
    // Every bitPerfectOutput write requests this: the FX and crossfade
    // branches are what withdraw FX and drop the crossfade under the mode.
    VibeSettingsLiveEffectBitPerfectApply  = VibeSettingsLiveEffectBitPerfect
                                           | VibeSettingsLiveEffectFXControls
                                           | VibeSettingsLiveEffectCrossfade,
    VibeSettingsLiveEffectAll              = NSUIntegerMax,
};

@interface MainPlayerController (Settings)

// Pushes the theme's fonts into Fonts, which may not read a setting.
// buildContentInWindow: runs it before any label exists.
- (void)applyStoredFonts;

// Applies settings already stored. Never writes settings or window geometry.
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects;
// NO for a device settlement: its modes are applied, and the player may have
// moved on to another device.
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects updatingOutputModes:(BOOL)updatingOutputModes;

@end

NS_ASSUME_NONNULL_END
