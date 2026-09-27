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

// Same hue, alphas aside (Mono). The iOS scrubber's fast path then draws the
// unplayed side as the played bitmap at unplayedOverPlayedOpacity rather than
// baking its own.
@property (readonly) BOOL unplayedSharesPlayedHue;

// No vertical ramp: every stop is the side's color as-is. macOS only.
@property (nonatomic) BOOL flatFill;

#if TARGET_OS_OSX
// Every mac surface that draws a waveform maps the theme record through here,
// so a new waveform field is mapped once.
+ (WaveformTheme *)themeForAppTheme:(AppTheme *)theme isDark:(BOOL)isDark
                       artworkColor:(nullable VibeColor *)artworkColor;
#endif

// The renderers' default before a view resolves anything.
+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark;

@end

NS_ASSUME_NONNULL_END
