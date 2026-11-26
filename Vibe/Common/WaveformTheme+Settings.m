//
//  WaveformTheme+Settings.m
//  Vibe
//

#import "WaveformTheme+Settings.h"
#import "WaveformRendererRegistry.h"

@implementation WaveformTheme (Settings)

#if TARGET_OS_OSX
+ (WaveformTheme *)themeForAppTheme:(AppTheme *)theme isDark:(BOOL)isDark
                       artworkColor:(VibeColor *)artworkColor {
    // The band styles hide the waveform color. Their played side is Mono's,
    // because the hover and the volume bar read it.
    VibeWaveformPaletteKind kind = [WaveformRendererRegistry paletteKindForIdentifier:theme.waveformStyle];
    WaveformTheme *resolved = [self themeForIdentifier:kind != VibeWaveformPaletteKindTheme
                                                       ? SETTINGS_VALUE_WAVEFORM_THEME_MONO : theme.waveformTheme
                                                isDark:isDark
                                          artworkColor:artworkColor
                                          customPlayed:[theme colorForBase:kVibeThemeColorWaveformPlayed dark:isDark]
                                        customUnplayed:[theme colorForBase:kVibeThemeColorWaveformUnplayed dark:isDark]];
    resolved.flatFill = !theme.waveformGradient;
    if (kind != VibeWaveformPaletteKindTheme) {
        // The band wells: 3-Band's palette, and Spectrum's Custom.
        NSArray<VibeColor *> *wells = @[[theme displayColorForBase:kVibeThemeColorWaveformLow dark:isDark],
                                        [theme displayColorForBase:kVibeThemeColorWaveformMid dark:isDark],
                                        [theme displayColorForBase:kVibeThemeColorWaveformHigh dark:isDark]];
        if (kind == VibeWaveformPaletteKindBands) {
            resolved.bandColors = [self bandColorsForWells:wells shaded:theme.waveformShadeOverlaps isDark:isDark];
        } else {
            resolved.spectrumColors = [self spectrumColorsForIdentifier:theme.waveformSpectrumPalette isDark:isDark
                                                            customBands:wells];
            resolved.spectrumColorsBySection = [theme.waveformSpectrumColoring
                    isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS];
        }
    }
    if (theme.waveformPlayheadLine) {
        resolved.playheadColor = [theme displayColorForBase:kVibeThemeColorWaveformPlayhead dark:isDark];
    }
    return resolved;
}
#endif

#if !TARGET_OS_OSX
+ (WaveformTheme *)themeForSettings:(AppSettings *)settings widget:(BOOL)widget isDark:(BOOL)isDark
                       artworkColor:(VibeColor *)artworkColor {
    WaveformThemeChoice *choice = [[WaveformThemeChoice alloc] init];
    choice.theme = [settings waveformThemeForWidget:widget];
    choice.customPlayed = [settings waveformCustomPlayedColorForDark:isDark widget:widget];
    choice.customUnplayed = [settings waveformCustomUnplayedColorForDark:isDark widget:widget];
    choice.bandTheme = [settings waveformBandThemeForWidget:widget];
    choice.spectrumPalette = [settings waveformSpectrumPaletteForWidget:widget];
    choice.spectrumColoring = [settings waveformSpectrumColoringForWidget:widget];
    // The band wells, which 3-Band's and Spectrum's Custom share.
    choice.customLow = [settings waveformCustomBandColor:0 forDark:isDark widget:widget];
    choice.customMid = [settings waveformCustomBandColor:1 forDark:isDark widget:widget];
    choice.customHigh = [settings waveformCustomBandColor:2 forDark:isDark widget:widget];
    return [self themeForChoice:choice isDark:isDark artworkColor:artworkColor];
}

+ (NSString *)styleForSettings:(AppSettings *)settings widget:(BOOL)widget {
    NSString *style = (widget ? settings.widgetWaveformStyle : nil) ?: settings.waveformStyle;
    return [WaveformRendererRegistry resolveStyleIdentifier:style];
}

+ (BOOL)drawsPlayheadLineForSettings:(AppSettings *)settings widget:(BOOL)widget {
    return [WaveformRendererRegistry drawsPlayheadLineForIdentifier:[self styleForSettings:settings widget:widget]
                                                             chosen:[settings waveformPlayheadLineForWidget:widget]];
}

+ (WaveformThemeProvider)themeProviderForWidget:(BOOL)widget {
    return widget ? ^WaveformTheme *(BOOL isDark, VibeColor *artworkColor) {
        return [WaveformTheme themeForSettings:AppSettings.sharedInstance widget:YES isDark:isDark
                                  artworkColor:artworkColor];
    } : ^WaveformTheme *(BOOL isDark, VibeColor *artworkColor) {
        return [WaveformTheme themeForSettings:AppSettings.sharedInstance widget:NO isDark:isDark
                                  artworkColor:artworkColor];
    };
}
#endif

@end
