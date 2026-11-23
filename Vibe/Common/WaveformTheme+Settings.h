//
//  WaveformTheme+Settings.h
//  Vibe
//
//  Vibe's stores mapped onto the waveform's palette: the mac's theme record
//  and the iOS card's or widget's settings. WaveformTheme itself reads
//  neither. Precedent: AppSettings+Themes.
//

#import "WaveformTheme.h"
#import "AppSettings.h"
#if TARGET_OS_OSX
#import "AppTheme.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@interface WaveformTheme (Settings)

#if TARGET_OS_OSX
// Every mac surface that draws a waveform maps the theme record through here,
// so a new waveform field is mapped once.
+ (WaveformTheme *)themeForAppTheme:(AppTheme *)theme isDark:(BOOL)isDark
                       artworkColor:(nullable VibeColor *)artworkColor;
#endif

#if !TARGET_OS_OSX
// Every iOS surface that draws a waveform maps the loose settings through
// here, as the mac maps its theme record. widget reads the widget's copies
// (AppSettings.h).
+ (WaveformTheme *)themeForSettings:(AppSettings *)settings widget:(BOOL)widget isDark:(BOOL)isDark
                       artworkColor:(nullable VibeColor *)artworkColor;

// The rest of the look the card's scrubber and the widget's publisher are
// pushed. The style is resolved. A nil widget style is Match app, which
// draws the card's. The playhead line is the style's default until its
// switch is touched (Settings/AGENTS.md).
+ (NSString *)styleForSettings:(AppSettings *)settings widget:(BOOL)widget;
+ (BOOL)drawsPlayheadLineForSettings:(AppSettings *)settings widget:(BOOL)widget;
// A global block that reads the settings at each call.
+ (WaveformThemeProvider)themeProviderForWidget:(BOOL)widget;
#endif

@end

NS_ASSUME_NONNULL_END
