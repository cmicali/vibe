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

// The Mono theme is the pre-theme monochrome look exactly: the base hue,
// carrying the resting alphas that used to live in the Detailed renderer
// (its old stop alphas times its old 0.75 layer opacity).
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

// Orange is the pre-theme Sonic Cirrus pairing on every style: the hardcoded
// orange at full strength over the appearance's base at SC's historical
// unplayed alpha.
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

// A saturated art color survives, blended toward the appearance's contrast
// pole until its LUMINANCE clears the bar — bright enough for the dark
// backdrop, dark enough for the light one — with the hue's character kept.
// HSB brightness would pass a pure blue untouched (B is already 1.0) even
// though it is perceptually far too dark.
- (void)testAlbumArtClampsLuminanceTowardThePole {
    CGFloat r, g, b;

    NSColor *pureBlue = [NSColor colorWithRed:0 green:0 blue:1 alpha:1];
    WaveformTheme *dark = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                     isDark:YES artworkColor:pureBlue
                                               customPlayed:nil customUnplayed:nil];
    GetRGB(dark.playedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(0.299 * r + 0.587 * g + 0.114 * b, 0.55, 0.005);
    XCTAssertGreaterThan(b, r);                           // still reads blue
    XCTAssertEqualWithAccuracy(Alpha(dark.playedColor), 1.0, 0.001);

    NSColor *brightYellow = [NSColor colorWithRed:1 green:0.95 blue:0.1 alpha:1];
    WaveformTheme *light = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                      isDark:NO artworkColor:brightYellow
                                                customPlayed:nil customUnplayed:nil];
    GetRGB(light.playedColor, &r, &g, &b);
    XCTAssertEqualWithAccuracy(0.299 * r + 0.587 * g + 0.114 * b, 0.45, 0.005);
    XCTAssertGreaterThan(r, b);                           // still reads yellow

    // Already legible: untouched.
    NSColor *midGreen = [NSColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1];
    WaveformTheme *asIs = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART
                                                     isDark:YES artworkColor:midGreen
                                               customPlayed:nil customUnplayed:nil];
    XCTAssertTrue(SameRGB(asIs.playedColor, midGreen));
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

// An unknown identifier resolves as mono rather than raising or going dark.
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
