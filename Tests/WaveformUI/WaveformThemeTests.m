//
//  WaveformThemeTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "WaveformTheme.h"

static void GetRGB(VibeColor *color, CGFloat *r, CGFloat *g, CGFloat *b) {
    NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat a = 0;
    [converted getRed:r green:g blue:b alpha:&a];
}

static CGFloat Luminance(VibeColor *color) {
    CGFloat r, g, b;
    GetRGB(color, &r, &g, &b);
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

static BOOL SameRGB(VibeColor *lhs, VibeColor *rhs) {
    CGFloat r1, g1, b1, r2, g2, b2;
    GetRGB(lhs, &r1, &g1, &b1);
    GetRGB(rhs, &r2, &g2, &b2);
    return fabs(r1 - r2) < 0.001 && fabs(g1 - g2) < 0.001 && fabs(b1 - b2) < 0.001;
}

static CGFloat Alpha(VibeColor *color) {
    return CGColorGetAlpha(color.CGColor);
}

@interface WaveformThemeTests : XCTestCase
@end

@implementation WaveformThemeTests

- (WaveformTheme *)themeFor:(NSString *)identifier isDark:(BOOL)isDark {
    return [WaveformTheme themeForIdentifier:identifier isDark:isDark
                                artworkColor:nil customPlayed:nil customUnplayed:nil];
}

- (void)testMonoReproducesMonochromeBase {
    WaveformTheme *dark = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_MONO isDark:YES];
    XCTAssertTrue(SameRGB(dark.playedColor, NSColor.whiteColor));
    XCTAssertTrue(SameRGB(dark.unplayedColor, NSColor.whiteColor));
    XCTAssertTrue(SameRGB(dark.hoverColor, NSColor.whiteColor));
    XCTAssertEqualWithAccuracy(Alpha(dark.playedColor), 0.75, 0.001);
    XCTAssertEqualWithAccuracy(Alpha(dark.unplayedColor), 0.375, 0.001);
    XCTAssertEqualWithAccuracy(Alpha(dark.hoverColor), 1.0, 0.001);

    WaveformTheme *light = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_MONO isDark:NO];
    XCTAssertTrue(SameRGB(light.playedColor, NSColor.blackColor));
    XCTAssertTrue(SameRGB(light.unplayedColor, NSColor.blackColor));
    XCTAssertTrue(SameRGB(light.hoverColor, NSColor.blackColor));
    XCTAssertEqualWithAccuracy(Alpha(light.playedColor), 0.75, 0.001);
    XCTAssertEqualWithAccuracy(Alpha(light.unplayedColor), 0.375, 0.001);
}

- (void)testOrangeMatchesSonicCirrusPairing {
    WaveformTheme *dark = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:YES];
    XCTAssertTrue(SameRGB(dark.playedColor, [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1]));
    XCTAssertEqualWithAccuracy(Alpha(dark.playedColor), 1.0, 0.001);
    XCTAssertTrue(SameRGB(dark.unplayedColor, NSColor.whiteColor));
    XCTAssertEqualWithAccuracy(Alpha(dark.unplayedColor), 0.89, 0.001);

    WaveformTheme *light = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:NO];
    XCTAssertTrue(SameRGB(light.playedColor, [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1]));
    XCTAssertTrue(SameRGB(light.unplayedColor, NSColor.blackColor));
    XCTAssertEqualWithAccuracy(Alpha(light.unplayedColor), 0.89, 0.001);
}

- (void)testAlbumArtFallsBackToMonoForMissingOrGrayArt {
    WaveformTheme *nilArt = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                       isDark:YES artworkColor:nil
                                                 customPlayed:nil customUnplayed:nil];
    XCTAssertTrue(SameRGB(nilArt.playedColor, NSColor.whiteColor));

    NSColor *gray = [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1];
    WaveformTheme *grayArt = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                        isDark:NO artworkColor:gray
                                                  customPlayed:nil customUnplayed:nil];
    XCTAssertTrue(SameRGB(grayArt.playedColor, NSColor.blackColor));
}

// Weighted RGB brightness catches dark saturated colors that HSB brightness
// would pass unchanged, such as pure blue.
- (void)testAlbumArtClampsLuminanceTowardThePole {
    CGFloat r, g, b;

    // The art hue is the UNPLAYED side — Orange's pairing reversed — under a
    // full-strength base played side.
    NSColor *pureBlue = [NSColor colorWithRed:0 green:0 blue:1 alpha:1];
    WaveformTheme *dark = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                     isDark:YES artworkColor:pureBlue
                                               customPlayed:nil customUnplayed:nil];
    XCTAssertTrue(SameRGB(dark.playedColor, NSColor.whiteColor));
    XCTAssertEqualWithAccuracy(Alpha(dark.playedColor), 1.0, 0.001);
    GetRGB(dark.unplayedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(0.299 * r + 0.587 * g + 0.114 * b, 0.55, 0.005);
    XCTAssertGreaterThan(b, r);                           // still reads blue
    XCTAssertEqualWithAccuracy(Alpha(dark.unplayedColor), 0.89, 0.001);

    NSColor *brightYellow = [NSColor colorWithRed:1 green:0.95 blue:0.1 alpha:1];
    WaveformTheme *light = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                      isDark:NO artworkColor:brightYellow
                                                customPlayed:nil customUnplayed:nil];
    XCTAssertTrue(SameRGB(light.playedColor, NSColor.blackColor));
    GetRGB(light.unplayedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(0.299 * r + 0.587 * g + 0.114 * b, 0.45, 0.005);
    XCTAssertGreaterThan(r, b);                           // still reads yellow

    // Muting toward the weighted gray preserves the brightness measure.
    NSColor *midGreen = [NSColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1];
    WaveformTheme *asIs = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                     isDark:YES artworkColor:midGreen
                                               customPlayed:nil customUnplayed:nil];
    CGFloat gray = 0.299 * 0.2 + 0.587 * 0.8 + 0.114 * 0.3;
    GetRGB(asIs.unplayedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(r, (0.2 + gray) / 2, 0.001);
    XCTAssertEqualWithAccuracy(g, (0.8 + gray) / 2, 0.001);
    XCTAssertEqualWithAccuracy(b, (0.3 + gray) / 2, 0.001);
    XCTAssertEqualWithAccuracy(0.299 * r + 0.587 * g + 0.114 * b, gray, 0.001);
    XCTAssertGreaterThan(g, r);                           // still reads green
}

- (void)testCustomCarriesItsAlphas {
    NSColor *played = [NSColor colorWithRed:0 green:0.8 blue:1 alpha:0.6];
    NSColor *unplayed = [NSColor colorWithRed:1 green:1 blue:1 alpha:0.25];
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                                                      isDark:YES artworkColor:nil
                                                customPlayed:played customUnplayed:unplayed];
    XCTAssertEqualWithAccuracy(Alpha(theme.playedColor), 0.6, 0.001);
    XCTAssertEqualWithAccuracy(Alpha(theme.unplayedColor), 0.25, 0.001);
    XCTAssertEqualWithAccuracy(Alpha(theme.hoverColor), 1.0, 0.001);
}

- (void)testCustomFallsBackToMonoWhenEitherColorIsUnset {
    NSColor *teal = [NSColor colorWithRed:0 green:0.7 blue:0.7 alpha:1];
    WaveformTheme *missing = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                                                        isDark:YES artworkColor:nil
                                                  customPlayed:teal customUnplayed:nil];
    XCTAssertTrue(SameRGB(missing.playedColor, NSColor.whiteColor));

    WaveformTheme *set = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                                                    isDark:YES artworkColor:nil
                                              customPlayed:teal customUnplayed:NSColor.whiteColor];
    XCTAssertTrue(SameRGB(set.playedColor, teal));
    XCTAssertTrue(SameRGB(set.unplayedColor, NSColor.whiteColor));
}

- (void)testUnknownIdentifierResolvesAsMono {
    WaveformTheme *theme = [self themeFor:@"lava_lamp" isDark:YES];
    XCTAssertTrue(SameRGB(theme.playedColor, NSColor.whiteColor));
}

#pragma mark 3-Band

static uint32_t RGBOf(VibeColor *color) {
    CGFloat r, g, b;
    GetRGB(color, &r, &g, &b);
    return (uint32_t)lround(r * 255) << 16 | (uint32_t)lround(g * 255) << 8 | (uint32_t)lround(b * 255);
}

static NSUInteger ChannelDistance(uint32_t lhs, uint32_t rhs) {
    NSUInteger worst = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        worst = MAX(worst, (NSUInteger)labs((long)(lhs >> shift & 0xff) - (long)(rhs >> shift & 0xff)));
    }
    return worst;
}

// The CDJ palette of hdelplan/three-band-waveform, which the shaded rule
// follows from its three bands.
static const uint32_t kCDJ[2][7] = {
    {0x0055e1, 0xd97706, 0x262626, 0xa35a0c, 0x17306b, 0x5c3a0e, 0x33302c},
    {0x0055e1, 0xffa600, 0xffffff, 0xb4690a, 0xd2dcfa, 0xfff0d7, 0xf5ebd7},
};

// Rekord Bin's bands, shaded, wherever a palette is resolved by identifier.
// The overlaps come from the rule, within 13/255 of the CDJ's own.
- (void)testBandsDefaultToRekordBin {
    for (int darkPass = 0; darkPass <= 1; darkPass++) {
        BOOL isDark = darkPass == 1;
        WaveformTheme *theme = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:isDark];
        XCTAssertEqual(theme.bandColors.count, 7u);
        for (NSUInteger layer = 0; layer < 7; layer++) {
            NSUInteger distance = ChannelDistance(RGBOf(theme.bandColors[layer]), kCDJ[darkPass][layer]);
            XCTAssertLessThanOrEqual(distance, layer < 3 ? 0u : 13u, @"layer %lu", (unsigned long)layer);
        }
    }
}

// An unknown band theme is Rekord Bin, and Custom is shaded.
- (void)testUnknownBandThemeIsRekordBinAndCustomIsShaded {
    NSArray<VibeColor *> *rekordBin = [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN
                                                                       isDark:YES customBands:@[]];
    NSArray<VibeColor *> *unknown = [WaveformTheme bandColorsForIdentifier:@"cdj" isDark:YES customBands:@[]];
    for (NSUInteger layer = 0; layer < 7; layer++) {
        XCTAssertEqual(RGBOf(unknown[layer]), RGBOf(rekordBin[layer]), @"layer %lu", (unsigned long)layer);
    }
    NSArray<VibeColor *> *custom = @[[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1],
                                     [NSColor colorWithSRGBRed:0 green:200 / 255.0 blue:0 alpha:1],
                                     [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1]];
    NSArray<VibeColor *> *bands = [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM
                                                                   isDark:YES customBands:custom];
    XCTAssertEqual(RGBOf(bands[0]), 0xff0000u);
    XCTAssertEqual(RGBOf(bands[3]), 0x008c00u, @"the mid shaded");
}

static NSArray<VibeColor *> *SpectrumPalette(NSString *identifier, BOOL isDark) {
    return [WaveformTheme spectrumColorsForIdentifier:identifier isDark:isDark customBands:@[]];
}

- (void)testSpectrumPalettes {
    for (int darkPass = 0; darkPass <= 1; darkPass++) {
        BOOL isDark = darkPass == 1;
        NSArray<VibeColor *> *rgb = SpectrumPalette(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, isDark);
        XCTAssertEqualObjects([self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:isDark].spectrumColors, rgb);
        XCTAssertEqualObjects(SpectrumPalette(@"rekord_bin", isDark), rgb);
        XCTAssertEqualObjects(SpectrumPalette(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM, isDark), rgb,
                              @"Custom without its three wells");
        CGFloat lightest = 0, darkest = 1;
        for (VibeColor *color in rgb) {
            lightest = MAX(lightest, Luminance(color));
            darkest = MIN(darkest, Luminance(color));
        }
        XCTAssertLessThan(lightest - darkest, 0.12, @"dark %d", darkPass);
        for (NSUInteger band = 0; band < 3; band++) {
            XCTAssertEqualWithAccuracy(Alpha(rgb[band]), 1, 0.001);
            CGFloat channels[3];
            GetRGB(rgb[band], &channels[0], &channels[1], &channels[2]);
            for (NSUInteger channel = 0; channel < 3; channel++) {
                if (channel != band) {
                    XCTAssertGreaterThan(channels[band], channels[channel], @"band %lu", (unsigned long)band);
                }
            }
        }
        struct { NSString *identifier; NSUInteger hue; } ramps[] = {
            {SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE, 2},
            {SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN, 1},
        };
        for (size_t i = 0; i < sizeof(ramps) / sizeof(ramps[0]); i++) {
            // The low, which most music is mostly, stands farthest from the background.
            NSArray<VibeColor *> *ramp = SpectrumPalette(ramps[i].identifier, isDark);
            NSArray<VibeColor *> *darkToLight = isDark ? ramp.reverseObjectEnumerator.allObjects : ramp;
            XCTAssertLessThan(Luminance(darkToLight[0]), Luminance(darkToLight[1]), @"%@", ramps[i].identifier);
            XCTAssertLessThan(Luminance(darkToLight[1]), Luminance(darkToLight[2]), @"%@", ramps[i].identifier);
            for (VibeColor *color in ramp) {
                CGFloat channels[3];
                GetRGB(color, &channels[0], &channels[1], &channels[2]);
                XCTAssertGreaterThanOrEqual(channels[ramps[i].hue], channels[0], @"%@", ramps[i].identifier);
                XCTAssertEqualWithAccuracy(Alpha(color), 1, 0.001);
            }
        }
    }
    for (NSString *palette in @[SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE,
                                SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN]) {
        for (NSUInteger band = 0; band < 3; band++) {
            XCTAssertLessThan(Luminance(SpectrumPalette(palette, NO)[band]), Luminance(SpectrumPalette(palette, YES)[band]),
                              @"%@ band %lu", palette, (unsigned long)band);
        }
    }
}

// Hover moves weighted RGB brightness toward the contrast pole by up to 0.25.
- (void)testHoverContrastHolds {
    NSColor *orange = [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1];
    struct { NSString *identifier; NSColor *played; NSColor *unplayed; } cases[] = {
        { SETTINGS_VALUE_WAVEFORM_THEME_ORANGE, orange, nil },
        { SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM, NSColor.whiteColor, NSColor.whiteColor },
        { SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM, NSColor.blackColor, NSColor.blackColor },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        for (int darkPass = 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            WaveformTheme *theme = [WaveformTheme themeForIdentifier:cases[i].identifier
                                                              isDark:isDark artworkColor:nil
                                                        customPlayed:cases[i].played
                                                      customUnplayed:cases[i].unplayed];
            CGFloat pole = isDark ? 1 : 0;
            CGFloat played = Luminance(theme.playedColor);
            CGFloat hover = Luminance(theme.hoverColor);
            CGFloat expected = fabs(pole - played) <= 0.25 ? pole
                    : played + (isDark ? 0.25 : -0.25);
            XCTAssertEqualWithAccuracy(hover, expected, 0.01,
                    @"case %zu dark=%d", i, isDark);
        }
    }
}

@end
