//
//  WaveformTheme+Settings.m
//  Vibe
//

#import "WaveformTheme+Settings.h"
#if TARGET_OS_OSX
#import "WaveformRendererRegistry.h"
#endif

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
    WaveformTheme *resolved = [self themeForIdentifier:[settings waveformThemeForWidget:widget]
                                                isDark:isDark
                                          artworkColor:artworkColor
                                          customPlayed:[settings waveformCustomPlayedColorForDark:isDark widget:widget]
                                        customUnplayed:[settings waveformCustomUnplayedColorForDark:isDark widget:widget]];
    // The custom bands, which 3-Band's and Spectrum's Custom share, read only
    // when either is chosen. An unset band draws Rekord Bin's, which is what
    // its well shows.
    NSString *bandTheme = [settings waveformBandThemeForWidget:widget];
    NSString *spectrumPalette = [settings waveformSpectrumPaletteForWidget:widget];
    NSMutableArray<VibeColor *> *custom = [NSMutableArray arrayWithCapacity:3];
    if ([bandTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM] ||
        [spectrumPalette isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM]) {
        for (NSUInteger band = 0; band < 3; band++) {
            [custom addObject:[settings waveformCustomBandColor:band forDark:isDark widget:widget] ?: resolved.bandColors[band]];
        }
    }
    resolved.bandColors = [self bandColorsForIdentifier:bandTheme isDark:isDark customBands:custom];
    resolved.spectrumColors = [self spectrumColorsForIdentifier:spectrumPalette isDark:isDark customBands:custom];
    resolved.spectrumColorsBySection = [[settings waveformSpectrumColoringForWidget:widget]
            isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS];
    return resolved;
}
#endif

@end
