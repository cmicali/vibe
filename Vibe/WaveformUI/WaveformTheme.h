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

// Waveform color theme identifiers, resolved to colors only by WaveformTheme.
#define SETTINGS_VALUE_WAVEFORM_THEME_MONO                  @"mono"
#define SETTINGS_VALUE_WAVEFORM_THEME_ORANGE                @"orange"
#define SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART             @"album_art"
#define SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM                @"custom"

// 3-Band's palettes on iOS, resolved to colors only by WaveformTheme. On macOS
// the theme's band wells are the palette.
#define SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN       @"rekord_bin"
#define SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE          @"dengine"
#define SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM           @"custom"

// Spectrum's palettes, resolved to colors only by WaveformTheme. Custom draws
// the band wells, which 3-Band's custom palette shares.
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB        @"rgb"
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE       @"blue"
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN      @"green"
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM     @"custom"

// Spectrum's coloring. Sections, the default, gives each section of the
// track one color. Precise colors each moment by its own mix.
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_PRECISE   @"precise"
#define SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS  @"sections"

NS_ASSUME_NONNULL_BEGIN

// Which of the theme's palettes a waveform style paints: the waveform theme's
// played and unplayed colors, 3-Band's bandColors, or Spectrum's
// spectrumColors. Each style answers for itself (WaveformRenderer).
typedef NS_ENUM(NSInteger, VibeWaveformPaletteKind) {
    VibeWaveformPaletteKindTheme,
    VibeWaveformPaletteKindBands,
    VibeWaveformPaletteKindSpectrum,
};

@interface WaveformTheme : NSObject

// Each side's hue at its resting alpha.
@property (readonly) VibeColor *playedColor;
@property (readonly) VibeColor *unplayedColor;

// The played color at full alpha, moved toward the contrast pole by up to
// 0.25 in weighted RGB brightness. Colors at the pole have no headroom.
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

// Played, unplayed, band and Spectrum colors as hex, and Spectrum's
// coloring. Key other drawing inputs separately, including flatFill and
// playheadColor.
@property (readonly) NSString *paletteSignature;

// No vertical ramp: every stop is the side's color as-is. macOS only.
@property (nonatomic) BOOL flatFill;

// 3-Band's seven opaque fills in its painter's order: low, mid, high, then
// low+mid, low+high, mid+high, and all three. Rekord Bin's unless a mac theme
// sets its bands or iOS picks another palette.
@property (nonatomic, copy) NSArray<VibeColor *> *bandColors;

// Spectrum's low, mid and high primaries, opaque. It mixes them per bar by
// the bands' energies. RGB's unless a mac theme or iOS picks another palette.
@property (nonatomic, copy) NSArray<VibeColor *> *spectrumColors;

// Spectrum gives each section of the track one color, its whole mix, in
// place of each moment's own. The renderer finds the sections.
@property (nonatomic) BOOL spectrumColorsBySection;

// spectrumColors for a SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_* identifier;
// an unknown one resolves as RGB. custom is the band wells' low, mid and high
// for this appearance, which Custom draws as they are.
+ (NSArray<VibeColor *> *)spectrumColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                          customBands:(NSArray<VibeColor *> *)custom;

// bandColors for a SETTINGS_VALUE_WAVEFORM_BAND_THEME_* identifier; an unknown
// one resolves as Rekord Bin. custom is the custom palette's low, mid and high
// for this appearance, shaded as Rekord Bin's are; the built-in palettes
// ignore it.
+ (NSArray<VibeColor *> *)bandColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                      customBands:(NSArray<VibeColor *> *)custom;

// bandColors from three wells, low, mid and high: the seven fills by the one
// rule. Shaded, they follow a CDJ. Unshaded, each band paints plainly over
// the ones below, as Engine DJ does.
+ (NSArray<VibeColor *> *)bandColorsForWells:(NSArray<VibeColor *> *)wells shaded:(BOOL)shaded isDark:(BOOL)isDark;

// Non-nil, the playhead is a line in this color over a waveform drawn wholly
// as played; nil, the played/unplayed boundary is the playhead. Each view
// draws the line and hands its renderer a progress of 1, so no renderer
// reads this.
@property (nonatomic, strong, nullable) VibeColor *playheadColor;

// The renderers' default before a view resolves anything.
+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark;

// album_art's clamp: the art color at full alpha, pushed toward the
// appearance's contrast pole until it reads; nil for no color or too gray a
// one.
+ (nullable VibeColor *)legibleArtworkColor:(nullable VibeColor *)color isDark:(BOOL)isDark;

@end

NS_ASSUME_NONNULL_END
