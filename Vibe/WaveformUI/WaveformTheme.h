//
//  WaveformTheme.h
//  Vibe
//
//  The waveform's palette, resolved from a theme identifier in exactly one
//  place. Each color carries its side's resting level in its ALPHA, and the
//  renderers keep only their ramp shapes, scaling every stop relative to it;
//  a custom well's alpha dials its side's whole intensity. The style is the
//  geometry; this is only the color.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class AppSettings;
@class AppTheme;

@interface WaveformTheme : NSObject

// Each side's hue at its resting alpha.
@property (readonly) VibeColor *playedColor;
@property (readonly) VibeColor *unplayedColor;

// playedColor's hue at full alpha, shifted toward the contrast pole until its
// luminance clears the played color's by ~0.25, so the highlight reads under
// any palette.
@property (readonly) VibeColor *hoverColor;

// identifier is a SETTINGS_VALUE_WAVEFORM_THEME_* value; an unknown one
// resolves as mono. artworkColor feeds album_art; nil or too gray falls back
// to mono. played/unplayed are the custom pair FOR THIS APPEARANCE, alpha
// included; nil falls back to mono.
+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(nullable VibeColor *)artworkColor
                         customPlayed:(nullable VibeColor *)played
                       customUnplayed:(nullable VibeColor *)unplayed;

// The resolved colors as hex: played, unplayed and the bands. Equal
// signatures draw alike, so a view re-bakes only when this changes.
// Spectrum's colors are left out, since they follow the appearance alone.
@property (readonly) NSString *paletteSignature;

// Same hue, alphas aside (Mono). The iOS scrubber's fast path then draws the
// unplayed side as the played bitmap at unplayedOverPlayedOpacity rather than
// baking its own.
@property (readonly) BOOL unplayedSharesPlayedHue;

// No vertical ramp: every stop is the side's color as-is. macOS only.
@property (nonatomic) BOOL flatFill;

// 3-Band's seven opaque fills in its painter's order: low, mid, high, then
// low+mid, low+high, mid+high, and all three. Rekord Bin's unless a mac theme
// sets its bands or iOS picks another palette.
@property (nonatomic, copy) NSArray<VibeColor *> *bandColors;

// Spectrum's low, mid and high primaries, opaque. It mixes them per bar by
// the bands' energies. They are fixed per appearance, as a DJ deck's spectrum
// colors are. No theme or band palette sets them.
@property (readonly) NSArray<VibeColor *> *spectrumColors;

// bandColors for a SETTINGS_VALUE_WAVEFORM_BAND_THEME_* identifier; an unknown
// one resolves as Rekord Bin. custom is the custom palette's low, mid and high
// for this appearance, shaded as Rekord Bin's are; the built-in palettes
// ignore it.
+ (NSArray<VibeColor *> *)bandColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                      customBands:(NSArray<VibeColor *> *)custom;

// Non-nil, the playhead is a line in this color over a waveform drawn wholly
// as played; nil, the played/unplayed boundary is the playhead. Each view
// draws the line and hands its renderer a progress of 1, so no renderer
// reads this.
@property (nonatomic, strong, nullable) VibeColor *playheadColor;

#if TARGET_OS_OSX
// Every mac surface that draws a waveform maps the theme record through here,
// so a new waveform field is mapped once.
+ (WaveformTheme *)themeForAppTheme:(AppTheme *)theme isDark:(BOOL)isDark
                       artworkColor:(nullable VibeColor *)artworkColor;
#endif

#if !TARGET_OS_OSX
// Every iOS surface that draws a waveform maps the loose settings through
// here, as the mac maps its theme record.
+ (WaveformTheme *)themeForSettings:(AppSettings *)settings isDark:(BOOL)isDark
                       artworkColor:(nullable VibeColor *)artworkColor;
#endif

// The renderers' default before a view resolves anything.
+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark;

// album_art's clamp: the art color at full alpha, pushed toward the
// appearance's contrast pole until it reads; nil for no color or too gray a
// one.
+ (nullable VibeColor *)legibleArtworkColor:(nullable VibeColor *)color isDark:(BOOL)isDark;

@end

NS_ASSUME_NONNULL_END
