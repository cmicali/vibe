//
//  WaveformThemeSettingsTests.m
//  VibeTests
//
//  The mac's mapping of a theme record onto the waveform theme
//  (WaveformTheme+Settings). The theme's own palettes are vibe-libs'
//  WaveformThemeTests.
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "WaveformTheme.h"
#import "WaveformTheme+Settings.h"
#import "AppSettings.h"
#import "AppTheme.h"

static void GetRGB(VibeColor *color, CGFloat *r, CGFloat *g, CGFloat *b) {
    NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat a = 0;
    [converted getRed:r green:g blue:b alpha:&a];
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

// The CDJ palette of hdelplan/three-band-waveform, as WaveformThemeTests has it.
static const uint32_t kCDJ[2][7] = {
    {0x0055e1, 0xd97706, 0x262626, 0xa35a0c, 0x17306b, 0x5c3a0e, 0x33302c},
    {0x0055e1, 0xffa600, 0xffffff, 0xb4690a, 0xd2dcfa, 0xfff0d7, 0xf5ebd7},
};

static AppTheme *ThreeBandRecord(NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"waveformStyle"] = @"three_band";
    return [[AppTheme alloc] initWithRecord:record];
}

static NSArray<VibeColor *> *SpectrumPalette(NSString *identifier, BOOL isDark) {
    return [WaveformTheme spectrumColorsForIdentifier:identifier isDark:isDark customBands:@[]];
}

@interface WaveformThemeSettingsTests : XCTestCase
@end

@implementation WaveformThemeSettingsTests

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
    XCTAssertEqualWithAccuracy(Alpha(light.playheadColor), 0.8, 0.001);
}

#pragma mark 3-Band

// A mac theme whose band wells are unset draws Rekord Bin's bands, shaded. The
// overlaps come from the rule, within 13/255 of the CDJ's own.
- (void)testUnsetBandWellsAreRekordBin {
    for (int darkPass = 0; darkPass <= 1; darkPass++) {
        BOOL isDark = darkPass == 1;
        WaveformTheme *theme = [WaveformTheme themeForAppTheme:ThreeBandRecord(@{}) isDark:isDark artworkColor:nil];
        XCTAssertEqual(theme.bandColors.count, 7u);
        for (NSUInteger layer = 0; layer < 7; layer++) {
            NSUInteger distance = ChannelDistance(RGBOf(theme.bandColors[layer]), kCDJ[darkPass][layer]);
            XCTAssertLessThanOrEqual(distance, layer < 3 ? 0u : 13u, @"layer %lu", (unsigned long)layer);
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

// iOS's palettes reproduce the mac's built-in 3-Band themes in dark, where
// Dengine is drawn.
- (void)testBandThemesMatchTheMacThemes {
    NSArray<VibeColor *> *(^mac)(NSString *) = ^NSArray<VibeColor *> *(NSString *identifier) {
        AppTheme *theme = [[AppTheme alloc] initWithRecord:[AppTheme builtInRecordForIdentifier:identifier]];
        return [WaveformTheme themeForAppTheme:theme isDark:YES artworkColor:nil].bandColors;
    };
    NSArray<VibeColor *> *rekordBin = [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN
                                                                       isDark:YES customBands:@[]];
    NSArray<VibeColor *> *dengine = [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE
                                                                     isDark:YES customBands:@[]];
    for (NSUInteger layer = 0; layer < 7; layer++) {
        XCTAssertEqual(RGBOf(rekordBin[layer]), RGBOf(mac(@"rekord_bin")[layer]), @"layer %lu", (unsigned long)layer);
        XCTAssertEqual(RGBOf(dengine[layer]), RGBOf(mac(@"dengine")[layer]), @"layer %lu", (unsigned long)layer);
    }
}

// The wells' colors as the bands, stored opaque whatever their alpha, since
// the layers stack; the overlaps blend them.
- (void)testBandWellsStoreOpaque {
    AppTheme *record = ThreeBandRecord(@{});
    [record setColor:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:0.5] forBase:kVibeThemeColorWaveformLow dark:YES];
    XCTAssertEqualObjects(record.dictionaryRepresentation[@"waveformLowColorDark"], @"#FF0000");
    XCTAssertTrue([AppTheme storesOpaqueColorBase:kVibeThemeColorWaveformLow]);
    XCTAssertFalse([AppTheme storesOpaqueColorBase:kVibeThemeColorWaveformPlayed]);
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

#pragma mark Spectrum

- (void)testSpectrumTakesTheThemesPalette {
    AppTheme *blue = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"spectrum",
                                                        @"waveformSpectrumPalette": @"blue",
                                                        @"waveformTheme": @"orange"}];
    WaveformTheme *resolved = [WaveformTheme themeForAppTheme:blue isDark:YES artworkColor:nil];
    XCTAssertEqualObjects(resolved.spectrumColors, SpectrumPalette(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE, YES));
    XCTAssertTrue(SameRGB(resolved.playedColor, NSColor.whiteColor));

    AppTheme *custom = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"spectrum",
                                                          @"waveformSpectrumPalette": @"custom"}];
    [custom setColor:[NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1] forBase:kVibeThemeColorWaveformLow dark:YES];
    NSArray<VibeColor *> *wells = [WaveformTheme themeForAppTheme:custom isDark:YES artworkColor:nil].spectrumColors;
    XCTAssertEqual(RGBOf(wells[0]), 0xff00ffu);
    XCTAssertEqual(RGBOf(wells[1]), 0xffa600u, @"an unset well draws Rekord Bin's band");
    XCTAssertEqual(RGBOf(wells[2]), 0xffffffu);

    AppTheme *detailed = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"detailed",
                                                            @"waveformSpectrumPalette": @"blue"}];
    XCTAssertEqualObjects([WaveformTheme themeForAppTheme:detailed isDark:YES artworkColor:nil].spectrumColors,
                          SpectrumPalette(SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB, YES),
                          @"no band style, so the palette is not resolved");
}

- (void)testSpectrumTakesTheThemesColoring {
    AppTheme *precise = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"spectrum",
                                                           @"waveformSpectrumColoring": @"precise"}];
    AppTheme *sections = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"spectrum"}];
    WaveformTheme *byMoment = [WaveformTheme themeForAppTheme:precise isDark:YES artworkColor:nil];
    WaveformTheme *bySection = [WaveformTheme themeForAppTheme:sections isDark:YES artworkColor:nil];
    XCTAssertFalse(byMoment.spectrumColorsBySection);
    XCTAssertTrue(bySection.spectrumColorsBySection);
    XCTAssertNotEqualObjects(byMoment.paletteSignature, bySection.paletteSignature,
                             @"a bake keyed by the palette re-bakes on a coloring change");
}

@end
