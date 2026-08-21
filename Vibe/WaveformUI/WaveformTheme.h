//
//  WaveformTheme.h
//  Vibe
//
//  The waveform's palette, resolved from a theme identifier in exactly one
//  place. Each color carries its side's resting level in its ALPHA — the
//  levels that once lived in the renderers as constants — and the renderers
//  keep only their ramp shapes, scaling every stop relative to the color's
//  own alpha. The Mono pair's alphas reproduce the pre-theme monochrome
//  output pixel for pixel; a custom well's alpha dials its side's whole
//  intensity. The style setting stays the geometry; this is only the color.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface WaveformTheme : NSObject

// The played side of the progress boundary: the hue at the side's resting
// alpha.
@property (readonly) VibeColor *playedColor;

// The unplayed side, likewise.
@property (readonly) VibeColor *unplayedColor;

// The hover column/bar color, derived from playedColor's hue: full alpha,
// shifted toward white in dark mode and black in light until its luminance
// clears the played color's by ~0.25, so the highlight stays readable under
// any palette — a near-white custom played color would otherwise swallow the
// old "base at full alpha" rule.
@property (readonly) VibeColor *hoverColor;

// The one home of the resolution rules. identifier is a
// SETTINGS_VALUE_WAVEFORM_THEME_* value (AppSettings.h); an unknown one
// resolves as mono. artworkColor is the current track's dominant art color
// for album_art — nil or too gray to read falls back to mono's answer.
// played/unplayed are the custom pair FOR THIS APPEARANCE — the store keeps a
// pair per appearance and the resolver passes the matching one — alpha
// included, nil falling back to mono's answer.
+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(nullable VibeColor *)artworkColor
                         customPlayed:(nullable VibeColor *)played
                       customUnplayed:(nullable VibeColor *)unplayed;

// YES when unplayedColor is the same hue as playedColor, alphas aside — the
// Mono theme, one hue at two levels. The iOS scrubber's settled fast path
// asks: with one hue the unplayed bitmap is the played bitmap at
// unplayedOverPlayedOpacity, with two it needs its own bake.
@property (readonly) BOOL unplayedSharesPlayedHue;

// Mono's answer: the pre-theme monochrome palette for the appearance. The
// renderers' default before a view resolves anything.
+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark;

@end

NS_ASSUME_NONNULL_END
