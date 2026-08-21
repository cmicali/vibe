//
//  WaveformTheme.m
//  Vibe
//

#import "WaveformTheme.h"
#import "AppSettings.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

// The hover highlight's required luminance separation from the played color.
static const CGFloat kHoverLuminanceDelta = 0.25;

// The resting alphas the built-in themes' colors carry — the levels that used
// to live in the renderers. The monochrome pair reproduces the pre-theme
// Detailed output exactly (its old stop alphas times its old 0.75 layer
// opacity); the colored unplayed level is Sonic Cirrus's historical unplayed
// alpha, so the colored themes pair a full-strength hue with SC's bright
// monochrome — the classic Sonic Cirrus look, on every style. Colored played
// is simply full alpha.
static const CGFloat kMonochromePlayedAlpha = 0.75;
static const CGFloat kMonochromeUnplayedAlpha = 0.375;
static const CGFloat kColoredUnplayedAlpha = 0.89;

// The album-art legibility clamp. Below the saturation floor the dominant
// color is effectively grayscale and the theme falls back to mono. The level
// test is perceptual luminance, not HSB brightness, which is hue-blind — a
// pure blue reads B=1.0 yet is far too dark for the dark backdrop — and the
// fix blends toward the appearance's contrast pole, which moves luminance for
// any hue where scaling components cannot.
static const CGFloat kArtworkSaturationFloor = 0.15;
static const CGFloat kArtworkDarkMinLuminance = 0.55;
static const CGFloat kArtworkLightMaxLuminance = 0.45;

static BOOL VibeGetRGB(VibeColor *color, CGFloat *r, CGFloat *g, CGFloat *b) {
    CGFloat a = 0;
#if TARGET_OS_OSX
    NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!converted) {
        return NO;
    }
    [converted getRed:r green:g blue:b alpha:&a];
    return YES;
#else
    return [color getRed:r green:g blue:b alpha:&a];
#endif
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
        CGFloat pr, pg, pb, ur, ug, ub;
        // RGB only, alphas aside on purpose: the White pair is one hue at two
        // levels, and the iOS scrubber's single-bitmap fast path recovers the
        // level difference from unplayedOverPlayedOpacity.
        _unplayedSharesPlayedHue = played == unplayed ||
                (VibeGetRGB(played, &pr, &pg, &pb) && VibeGetRGB(unplayed, &ur, &ug, &ub) &&
                 fabs(pr - ur) < 0.001 && fabs(pg - ug) < 0.001 && fabs(pb - ub) < 0.001);
    }
    return self;
}

+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark {
    return [self themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_MONO isDark:isDark
                       artworkColor:nil customPlayed:nil customUnplayed:nil];
}

+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(VibeColor *)artworkColor
                         customPlayed:(VibeColor *)played
                       customUnplayed:(VibeColor *)unplayed {
    // The monochrome base every fallback lands on: white-based in dark mode,
    // black-based in light — exactly the pre-theme palette.
    VibeColor *base = isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    VibeColor *coloredUnplayed = [base colorWithAlphaComponent:kColoredUnplayedAlpha];

    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE]) {
        // Sonic Cirrus's played orange over its bright monochrome unplayed,
        // now available to every style.
        VibeColor *orange = [VibeColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        return [[self alloc] initWithPlayed:orange unplayed:coloredUnplayed isDark:isDark];
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]) {
        VibeColor *clamped = [self legibleArtworkColor:artworkColor isDark:isDark];
        if (clamped) {
            // Orange's pairing reversed: the base carries the played side at
            // full strength and the art's hue colors what is still to come.
            return [[self alloc] initWithPlayed:base
                                       unplayed:[clamped colorWithAlphaComponent:kColoredUnplayedAlpha]
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

// nil when the color cannot supply a legible hue at all; otherwise the color
// blended toward the appearance's contrast pole until its luminance clears
// the bar — bright enough for the dark backdrop, dark enough for the light
// one. The blend desaturates a little; that is the price of a hue like pure
// blue ever reaching a readable level. Full alpha: the played side of a
// colored theme draws at full strength.
+ (VibeColor *)legibleArtworkColor:(VibeColor *)color isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!color || !VibeGetRGB(color, &r, &g, &b)) {
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
        // Luminance is linear in the blend, so the fraction is closed form.
        CGFloat headroom = fabs(pole - luminance);
        CGFloat t = headroom > 0 ? MIN(shortfall / headroom, 1) : 0;
        r += (pole - r) * t;
        g += (pole - g) * t;
        b += (pole - b) * t;
    }
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

+ (VibeColor *)hoverColorForPlayed:(VibeColor *)played isDark:(BOOL)isDark {
    CGFloat r, g, b;
    if (!VibeGetRGB(played, &r, &g, &b)) {
        return isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    }
    // Blend toward the appearance's contrast pole — white in dark mode, black
    // in light — just far enough that the luminance delta clears the
    // threshold. Luminance is linear in the blend, so the fraction is closed
    // form; a played color already at the pole saturates there, which is what
    // keeps the Mono theme's hover identical to the pre-theme one. Full
    // alpha regardless of the played level: the highlight is meant to be the
    // brightest thing in the waveform.
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
