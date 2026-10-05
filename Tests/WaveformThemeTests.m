//
//  WaveformThemeTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "WaveformTheme.h"
#import "AppSettings.h"
#import "AppTheme.h"

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

// Album art with no color, or a grayscale one, is Mono's answer.
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

// A saturated art color is blended toward the appearance's contrast pole until
// its luminance clears the bar, keeping its hue. HSB brightness would pass a
// pure blue untouched (B is already 1.0) though it reads far too dark.
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

    // Already legible: no level correction, only the mute — the hue pulled
    // halfway to its own luminance gray, which leaves that luminance alone.
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

// The custom pair passes through as stored, alpha included — a well's alpha
// is its side's resting level.
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

// Custom with either color missing is Mono's answer.
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

// An unknown identifier resolves as mono rather than raising or going dark.
- (void)testUnknownIdentifierResolvesAsMono {
    WaveformTheme *theme = [self themeFor:@"lava_lamp" isDark:YES];
    XCTAssertTrue(SameRGB(theme.playedColor, NSColor.whiteColor));
}

// The mac's mapping. Off is no line whatever the pair holds, so a theme that
// never asked keeps the dimmed unplayed side; on is the pair's side, the
// appearance's contrast pole while unset.
- (void)testPlayheadColorFollowsTheThemesSwitchAndPair {
    AppTheme *record = [[AppTheme alloc] initWithRecord:nil];
    [record setColor:NSColor.redColor forBase:kVibeThemeColorWaveformPlayhead dark:YES];
    XCTAssertNil([WaveformTheme themeForAppTheme:record isDark:YES artworkColor:nil].playheadColor);

    record.waveformPlayheadLine = YES;
    WaveformTheme *dark = [WaveformTheme themeForAppTheme:record isDark:YES artworkColor:nil];
    XCTAssertTrue(SameRGB(dark.playheadColor, NSColor.redColor));
    WaveformTheme *light = [WaveformTheme themeForAppTheme:record isDark:NO artworkColor:nil];
    XCTAssertTrue(SameRGB(light.playheadColor, NSColor.blackColor));
    XCTAssertEqualWithAccuracy(Alpha(light.playheadColor), 1.0, 0.001);
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

static AppTheme *ThreeBandRecord(NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"waveformStyle"] = @"three_band";
    return [[AppTheme alloc] initWithRecord:record];
}

// Rekord Bin's bands, shaded, wherever a palette is resolved: iOS's identifier
// path, and a mac theme whose band wells are unset. The overlaps come from the
// rule, within 13/255 of the CDJ's own.
- (void)testBandsDefaultToRekordBin {
    for (int darkPass = 0; darkPass <= 1; darkPass++) {
        BOOL isDark = darkPass == 1;
        for (WaveformTheme *theme in @[[self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:isDark],
                                       [WaveformTheme themeForAppTheme:ThreeBandRecord(@{}) isDark:isDark
                                                          artworkColor:nil]]) {
            XCTAssertEqual(theme.bandColors.count, 7u);
            for (NSUInteger layer = 0; layer < 7; layer++) {
                NSUInteger distance = ChannelDistance(RGBOf(theme.bandColors[layer]), kCDJ[darkPass][layer]);
                XCTAssertLessThanOrEqual(distance, layer < 3 ? 0u : 13u, @"layer %lu", (unsigned long)layer);
            }
        }
    }
}

// Unshaded, each band is painted whole over the ones below, as Engine DJ's
// deck is: the Dengine theme's bands reproduce the colors sampled off it.
- (void)testUnshadedOverlapsAreEngineDJs {
    AppTheme *dengine = [[AppTheme alloc] initWithRecord:[AppTheme builtInRecordForIdentifier:@"dengine"]];
    XCTAssertFalse(dengine.waveformShadeOverlaps);
    NSArray<VibeColor *> *bands = [WaveformTheme themeForAppTheme:dengine isDark:YES artworkColor:nil].bandColors;
    const uint32_t sampled[7] = {0x2f69e0, 0x4cdf80, 0xffffff, 0x4cdf80, 0xf3f6fd, 0xf4fdf7, 0xf4fdf7};
    for (NSUInteger layer = 0; layer < 7; layer++) {
        XCTAssertEqual(RGBOf(bands[layer]), sampled[layer], @"layer %lu", (unsigned long)layer);
    }
}

// The wells' colors as the bands, stored opaque whatever their alpha, since
// the layers stack; the overlaps blend them.
- (void)testBandWellsStoreOpaque {
    AppTheme *record = ThreeBandRecord(@{});
    [record setColor:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:0.5] forBase:kVibeThemeColorWaveformLow dark:YES];
    XCTAssertEqualObjects(record.dictionaryRepresentation[@"waveformLowColorDark"], @"#FF0000");
    [record setColor:[NSColor colorWithSRGBRed:0 green:200 / 255.0 blue:0 alpha:1] forBase:kVibeThemeColorWaveformMid dark:YES];
    [record setColor:[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] forBase:kVibeThemeColorWaveformHigh dark:YES];
    NSArray<VibeColor *> *bands = [WaveformTheme themeForAppTheme:record isDark:YES artworkColor:nil].bandColors;
    XCTAssertEqual(RGBOf(bands[0]), 0xff0000u);
    XCTAssertEqual(RGBOf(bands[1]), 0x00c800u);
    XCTAssertEqual(RGBOf(bands[2]), 0x0000ffu);
    for (VibeColor *color in bands) {
        XCTAssertEqualWithAccuracy(Alpha(color), 1, 0.001);
    }
    XCTAssertEqual(RGBOf(bands[3]), 0x008c00u, @"the mid shaded");
    XCTAssertEqual(RGBOf(bands[4]), 0x2e00d1u, @"the high tinted toward the low");
}

// 3-Band hides the waveform color, so its played side, which the hover and
// the volume bar read, is Mono's whatever the hidden choice holds.
- (void)testUnderThreeBandThePlayedSideIsMono {
    WaveformTheme *bands = [WaveformTheme themeForAppTheme:ThreeBandRecord(@{@"waveformTheme": @"orange"})
                                                    isDark:YES artworkColor:nil];
    XCTAssertTrue(SameRGB(bands.playedColor, NSColor.whiteColor));
    XCTAssertTrue(SameRGB(bands.hoverColor, NSColor.whiteColor));
    AppTheme *detailed = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"detailed", @"waveformTheme": @"orange"}];
    XCTAssertFalse(SameRGB([WaveformTheme themeForAppTheme:detailed isDark:YES artworkColor:nil].playedColor,
                           NSColor.whiteColor));
}

// Hover clears the played color's luminance by 0.25 toward the appearance's
// pole, saturating there, which keeps Mono's hover exactly the base.
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
