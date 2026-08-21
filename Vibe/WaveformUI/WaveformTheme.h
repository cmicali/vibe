//
//  WaveformTheme.h
//  Vibe
//
//  The waveform's palette, resolved from a theme identifier in exactly one
//  place. The theme supplies full-alpha base hues; each renderer family keeps
//  deriving its own gradient alphas from them, which is what lets the White
//  theme reproduce the pre-theme monochrome output pixel for pixel. The style
//  setting stays the geometry; this is only the color.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface WaveformTheme : NSObject

// Full-alpha base hue for the played side of the progress boundary.
@property (readonly) VibeColor *playedColor;

// Full-alpha base hue for the unplayed side.
@property (readonly) VibeColor *unplayedColor;

// The hover column/bar color, derived from playedColor: full alpha, shifted
// toward white in dark mode and black in light until its luminance clears the
// played color's by ~0.25, so the highlight stays readable under any palette
// — a near-white custom played color would otherwise swallow the old
// "base at full alpha" rule.
@property (readonly) VibeColor *hoverColor;

// The one home of the resolution rules. identifier is a
// SETTINGS_VALUE_WAVEFORM_THEME_* value (AppSettings.h); an unknown one
// resolves as white. artworkColor is the current track's dominant art color
// for album_art — nil or too gray/extreme to read falls back to white's
// answer. played/unplayed are the custom pair for custom, nil falling back to
// white's answer.
+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(nullable VibeColor *)artworkColor
                         customPlayed:(nullable VibeColor *)played
                       customUnplayed:(nullable VibeColor *)unplayed;

// White's answer: the pre-theme monochrome palette for the appearance. The
// renderers' default before a view resolves anything.
+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark;

@end

NS_ASSUME_NONNULL_END
