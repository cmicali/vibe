//
//  WaveformTheme.m
//  Vibe
//

#import "WaveformTheme.h"
#import "AppSettings.h"
#import "PlatformColor.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import "AppTheme.h"
#import "WaveformRendererRegistry.h"
#else
#import <UIKit/UIKit.h>
#endif

// The target change in weighted RGB brightness, limited by the contrast pole.
static const CGFloat kHoverLuminanceDelta = 0.25;

// The built-in themes' resting alpha levels.
static const CGFloat kMonochromePlayedAlpha = 0.75;
static const CGFloat kMonochromeUnplayedAlpha = 0.375;
static const CGFloat kColoredUnplayedAlpha = 0.89;

// Nearly gray artwork falls back to Mono. The clamp uses weighted RGB
// brightness. HSB brightness would accept a dark pure blue.
static const CGFloat kArtworkSaturationFloor = 0.15;
static const CGFloat kArtworkDarkMinLuminance = 0.55;
static const CGFloat kArtworkLightMaxLuminance = 0.45;

// Toward the color's own luminance gray, which leaves the clamp above intact.
static const CGFloat kArtworkUnplayedDesaturation = 0.5;

// Seven opaque fills in painter's order. Shaded overlaps darken low+mid
// and tint combinations with highs toward the lower bands. Unshaded highs
// blend in 6% of the bands beneath them.
static const CGFloat kBandLowMidShade = 0.3;
static const CGFloat kBandHighTintDark = 0.18;
static const CGFloat kBandHighTintLight = 0.35;
static const CGFloat kBandAllThreeTint = 0.6;
static const CGFloat kBandHighTintUnshaded = 0.06;

static NSArray<VibeColor *> *VibeBandColors(VibeColor *low, VibeColor *mid, VibeColor *high, BOOL shade,
                                            BOOL isDark) {
    VibeColor *lowMid = shade ? VibeColorBlended(mid, [VibeColor blackColor], kBandLowMidShade) : mid;
    CGFloat tint = !shade ? kBandHighTintUnshaded : isDark ? kBandHighTintDark : kBandHighTintLight;
    return @[low, mid, high, lowMid, VibeColorBlended(high, low, tint), VibeColorBlended(high, mid, tint),
             VibeColorBlended(high, lowMid, shade ? tint * kBandAllThreeTint : tint)];
}

// The built-in palettes. Rekord Bin's is shaded, and a mac theme draws it
// until it sets its own (AppTheme's unset band wells are these). Dengine's is
// Engine DJ's deck, unshaded; its dark bands are the Dengine theme's, and its
// light ones darken the mid and the high so they read on white.
static NSArray<VibeColor *> *VibeBuiltInBandColors(BOOL dengine, BOOL isDark) {
    static NSArray<VibeColor *> *colors[2][2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger dark = 0; dark < 2; dark++) {
            VibeColor *high = VibeColorFromHexString(dark ? @"FFFFFF" : @"262626");
            colors[0][dark] = VibeBandColors(VibeColorFromHexString(@"0055E1"),
                                             VibeColorFromHexString(dark ? @"FFA600" : @"D97706"),
                                             high, YES, dark);
            colors[1][dark] = VibeBandColors(VibeColorFromHexString(@"2F69E0"),
                                             VibeColorFromHexString(dark ? @"4CDF80" : @"16A34A"),
                                             high, NO, dark);
        }
    });
    return colors[dengine ? 1 : 0][isDark ? 1 : 0];
}

// RGB's highs lean toward cyan to remain visible on black.
// Each palette's light set is darker for white backgrounds.
static NSArray<VibeColor *> *VibeBuiltInSpectrumColors(NSString *palette, BOOL isDark) {
    static NSDictionary<NSString *, NSArray<NSArray<VibeColor *> *> *> *palettes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Per palette, the light set and then the dark one, each low to high.
        NSDictionary<NSString *, NSArray<NSArray<NSString *> *> *> *hex = @{
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB: @[@[@"D8300F", @"15802A", @"2A60E0"],
                                                            @[@"FF4018", @"30C828", @"5296FF"]],
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE: @[@[@"003A5C", @"0077B6", @"5BA4D0"],
                                                             @[@"006890", @"00A8E8", @"C8E0E8"]],
            SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN: @[@[@"0A4A1F", @"158A3A", @"5DB878"],
                                                              @[@"0E6B2C", @"2ECC5B", @"C8F0CF"]],
        };
        NSMutableDictionary *built = [NSMutableDictionary dictionary];
        [hex enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSArray<NSArray<NSString *> *> *sets, BOOL *stop) {
            NSMutableArray *colorSets = [NSMutableArray array];
            for (NSArray<NSString *> *set in sets) {
                [colorSets addObject:@[VibeColorFromHexString(set[0]), VibeColorFromHexString(set[1]),
                                       VibeColorFromHexString(set[2])]];
            }
            built[name] = colorSets;
        }];
        palettes = built;
    });
    NSArray<NSArray<VibeColor *> *> *sets = palettes[palette] ?: palettes[SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB];
    return sets[isDark ? 1 : 0];
}

static CGFloat VibeLuminance(CGFloat r, CGFloat g, CGFloat b) {
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

@implementation WaveformTheme

- (instancetype)initWithPlayed:(VibeColor *)played unplayed:(VibeColor *)unplayed isDark:(BOOL)isDark {
    self = [super init];
    if (self) {
        _playedColor = played;
        _unplayedColor = unplayed;
        _hoverColor = [WaveformTheme hoverColorForPlayed:played isDark:isDark];
        _bandColors = VibeBuiltInBandColors(NO, isDark);
        _spectrumColors = VibeBuiltInSpectrumColors(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, isDark);
    }
    return self;
}

- (NSString *)paletteSignature {
    NSMutableString *signature = [NSMutableString string];
    NSArray<VibeColor *> *colors = [[@[_playedColor, _unplayedColor] arrayByAddingObjectsFromArray:_bandColors]
            arrayByAddingObjectsFromArray:_spectrumColors];
    for (VibeColor *color in colors) {
        [signature appendFormat:@"%@,", VibeHexStringFromColor(color) ?: @""];
    }
    if (_spectrumColorsBySection) {
        [signature appendString:@"sections"];
    }
    return signature;
}

+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark {
    return [self themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_MONO isDark:isDark
                       artworkColor:nil customPlayed:nil customUnplayed:nil];
}

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
            resolved.bandColors = VibeBandColors(wells[0], wells[1], wells[2], theme.waveformShadeOverlaps, isDark);
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

+ (NSArray<VibeColor *> *)spectrumColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                          customBands:(NSArray<VibeColor *> *)custom {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM] && custom.count == 3) {
        return [custom copy];
    }
    // Custom without its wells, and any unknown, are RGB.
    return VibeBuiltInSpectrumColors(identifier, isDark);
}

+ (NSArray<VibeColor *> *)bandColorsForIdentifier:(NSString *)identifier isDark:(BOOL)isDark
                                      customBands:(NSArray<VibeColor *> *)custom {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE]) {
        return VibeBuiltInBandColors(YES, isDark);
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM] && custom.count == 3) {
        return VibeBandColors(custom[0], custom[1], custom[2], YES, isDark);
    }
    return VibeBuiltInBandColors(NO, isDark);
}

+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(VibeColor *)artworkColor
                         customPlayed:(VibeColor *)played
                       customUnplayed:(VibeColor *)unplayed {
    VibeColor *base = isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    VibeColor *coloredUnplayed = [base colorWithAlphaComponent:kColoredUnplayedAlpha];

    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE]) {
        VibeColor *orange = [VibeColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        return [[self alloc] initWithPlayed:orange unplayed:coloredUnplayed isDark:isDark];
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]) {
        VibeColor *clamped = [self legibleArtworkColor:artworkColor isDark:isDark];
        if (clamped) {
            // Orange's pairing reversed: the base carries the played side at
            // full strength and the art's hue colors what is still to come.
            VibeColor *muted = [self color:clamped desaturatedBy:kArtworkUnplayedDesaturation];
            return [[self alloc] initWithPlayed:base
                                       unplayed:[muted colorWithAlphaComponent:kColoredUnplayedAlpha]
                                         isDark:isDark];
        }
        // No art, or art too gray to yield a hue: mono's answer.
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM] && played && unplayed) {
        // As stored, alpha included: the wells' alpha IS the side's resting
        // level.
        return [[self alloc] initWithPlayed:played unplayed:unplayed isDark:isDark];
    }
    // mono, and every fallback.
    return [[self alloc] initWithPlayed:[base colorWithAlphaComponent:kMonochromePlayedAlpha]
                               unplayed:[base colorWithAlphaComponent:kMonochromeUnplayedAlpha]
                                 isDark:isDark];
}

// nil for a color with no legible hue; otherwise blended toward the
// appearance's contrast pole until its luminance clears the bar — the only
// move that reaches every hue, at the cost of a little saturation.
+ (VibeColor *)legibleArtworkColor:(VibeColor *)color isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!color || !VibeColorGetSRGB(color, &r, &g, &b)) {
        return nil;
    }
    CGFloat maxc = MAX(r, MAX(g, b));
    CGFloat minc = MIN(r, MIN(g, b));
    CGFloat saturation = maxc > 0 ? (maxc - minc) / maxc : 0;
    if (saturation < kArtworkSaturationFloor) {
        return nil;
    }
    CGFloat pole = isDark ? 1 : 0;
    CGFloat luminance = VibeLuminance(r, g, b);
    CGFloat shortfall = isDark ? kArtworkDarkMinLuminance - luminance
                               : luminance - kArtworkLightMaxLuminance;
    if (shortfall > 0) {
        // Weighted RGB brightness is linear in this blend.
        CGFloat headroom = fabs(pole - luminance);
        CGFloat t = headroom > 0 ? MIN(shortfall / headroom, 1) : 0;
        r += (pole - r) * t;
        g += (pole - g) * t;
        b += (pole - b) * t;
    }
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

+ (VibeColor *)color:(VibeColor *)color desaturatedBy:(CGFloat)amount {
    CGFloat r, g, b;
    if (!VibeColorGetSRGB(color, &r, &g, &b)) {
        return color;
    }
    CGFloat gray = VibeLuminance(r, g, b);
    return [VibeColor colorWithRed:r + (gray - r) * amount
                             green:g + (gray - g) * amount
                              blue:b + (gray - b) * amount
                             alpha:1];
}

+ (VibeColor *)hoverColorForPlayed:(VibeColor *)played isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!VibeColorGetSRGB(played, &r, &g, &b)) {
        return isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    }
    // Move toward the contrast pole by the available brightness delta.
    // Full alpha keeps the hover visible over a translucent unplayed color and
    // over the bands.
    CGFloat pole = isDark ? 1 : 0;
    CGFloat luminance = VibeLuminance(r, g, b);
    CGFloat headroom = fabs(pole - luminance);
    CGFloat t = headroom <= kHoverLuminanceDelta ? 1 : kHoverLuminanceDelta / headroom;
    r += (pole - r) * t;
    g += (pole - g) * t;
    b += (pole - b) * t;
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

@end
