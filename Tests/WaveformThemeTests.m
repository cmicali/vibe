//
//  WaveformThemeTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "WaveformTheme.h"
#import "AppSettings.h"

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

@interface WaveformThemeTests : XCTestCase
@end

@implementation WaveformThemeTests

- (WaveformTheme *)themeFor:(NSString *)identifier isDark:(BOOL)isDark {
    return [WaveformTheme themeForIdentifier:identifier isDark:isDark
                                artworkColor:nil customPlayed:nil customUnplayed:nil];
}

// The White theme is the pre-theme monochrome palette exactly: the base at
// full alpha on both sides, in both appearances.
- (void)testWhiteReproducesMonochromeBase {
    WaveformTheme *dark = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_WHITE isDark:YES];
    XCTAssertTrue(SameRGB(dark.playedColor, NSColor.whiteColor));
    XCTAssertTrue(SameRGB(dark.unplayedColor, NSColor.whiteColor));
    XCTAssertTrue(SameRGB(dark.hoverColor, NSColor.whiteColor));

    WaveformTheme *light = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_WHITE isDark:NO];
    XCTAssertTrue(SameRGB(light.playedColor, NSColor.blackColor));
    XCTAssertTrue(SameRGB(light.unplayedColor, NSColor.blackColor));
    XCTAssertTrue(SameRGB(light.hoverColor, NSColor.blackColor));
}

// Orange's played hue is Sonic Cirrus's hardcoded pair's top color; unplayed
// stays the monochrome base.
- (void)testOrangeMatchesSonicCirrusHue {
    WaveformTheme *dark = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:YES];
    XCTAssertTrue(SameRGB(dark.playedColor, [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1]));
    XCTAssertTrue(SameRGB(dark.unplayedColor, NSColor.whiteColor));

    WaveformTheme *light = [self themeFor:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE isDark:NO];
    XCTAssertTrue(SameRGB(light.playedColor, [NSColor colorWithRed:1 green:0.45 blue:0 alpha:1]));
    XCTAssertTrue(SameRGB(light.unplayedColor, NSColor.blackColor));
}

// Album art with no color, or a grayscale one, is White's answer.
- (void)testAlbumArtFallsBackToWhite {
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

// A saturated art color survives, brightness-nudged into the appearance's
// legibility window with the hue preserved.
- (void)testAlbumArtClampsBrightnessKeepingHue {
    NSColor *darkRed = [NSColor colorWithRed:0.3 green:0.02 blue:0.02 alpha:1];
    WaveformTheme *dark = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                     isDark:YES artworkColor:darkRed
                                               customPlayed:nil customUnplayed:nil];
    CGFloat r, g, b;
    GetRGB(dark.playedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(r, 0.55, 0.001);           // nudged to the dark window's floor
    XCTAssertEqualWithAccuracy(g / r, 0.02 / 0.3, 0.01);  // hue ratio preserved
    XCTAssertGreaterThan(r, g);
    XCTAssertGreaterThan(r, b);

    NSColor *brightYellow = [NSColor colorWithRed:1 green:0.95 blue:0.1 alpha:1];
    WaveformTheme *light = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                      isDark:NO artworkColor:brightYellow
                                                customPlayed:nil customUnplayed:nil];
    GetRGB(light.playedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(r, 0.75, 0.001);           // pulled down to the light window's ceiling
}

// Custom with either color missing is White's answer.
- (void)testCustomFallsBackToWhiteWhenUnset {
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

// An unknown identifier resolves as white rather than raising or going dark.
- (void)testUnknownIdentifierResolvesAsWhite {
    WaveformTheme *theme = [self themeFor:@"lava_lamp" isDark:YES];
    XCTAssertTrue(SameRGB(theme.playedColor, NSColor.whiteColor));
}

// The hover contrast rule: hover clears the played color's luminance by 0.25
// toward the appearance's pole, saturating at the pole — which is what keeps
// White's hover exactly the base.
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
