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

// The album-art legibility clamp. Below the saturation floor the dominant
// color is effectively grayscale and the theme falls back to white; a
// brightness outside the appearance's window is nudged to its nearest edge.
// The windows differ per appearance because the failure differs: too dark to
// read on the dark backdrop, too bright to read on the light one.
static const CGFloat kArtworkSaturationFloor = 0.15;
static const CGFloat kArtworkDarkBrightnessMin = 0.55;
static const CGFloat kArtworkDarkBrightnessMax = 1.0;
static const CGFloat kArtworkLightBrightnessMin = 0.20;
static const CGFloat kArtworkLightBrightnessMax = 0.75;

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
        _unplayedSharesPlayedHue = played == unplayed ||
                (VibeGetRGB(played, &pr, &pg, &pb) && VibeGetRGB(unplayed, &ur, &ug, &ub) &&
                 fabs(pr - ur) < 0.001 && fabs(pg - ug) < 0.001 && fabs(pb - ub) < 0.001);
        _playedColorIsChromatic = [WaveformTheme colorIsChromatic:played];
        _unplayedColorIsChromatic = [WaveformTheme colorIsChromatic:unplayed];
    }
    return self;
}

+ (BOOL)colorIsChromatic:(VibeColor *)color {
    CGFloat r, g, b;
    if (!VibeGetRGB(color, &r, &g, &b)) {
        return NO;
    }
    CGFloat maxc = MAX(r, MAX(g, b));
    CGFloat minc = MIN(r, MIN(g, b));
    CGFloat saturation = maxc > 0 ? (maxc - minc) / maxc : 0;
    return saturation >= 0.05;
}

+ (WaveformTheme *)monochromeThemeIsDark:(BOOL)isDark {
    return [self themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_WHITE isDark:isDark
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

    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE]) {
        // Sonic Cirrus's played orange, now available to every style.
        VibeColor *orange = [VibeColor colorWithRed:1 green:0.45 blue:0 alpha:1];
        return [[self alloc] initWithPlayed:orange unplayed:base isDark:isDark];
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]) {
        VibeColor *clamped = [self legibleArtworkColor:artworkColor isDark:isDark];
        if (clamped) {
            return [[self alloc] initWithPlayed:clamped unplayed:base isDark:isDark];
        }
        // No art, or art too gray to yield a hue: white's answer.
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM] && played && unplayed) {
        return [[self alloc] initWithPlayed:played unplayed:unplayed isDark:isDark];
    }
    // white, and every fallback.
    return [[self alloc] initWithPlayed:base unplayed:base isDark:isDark];
}

// nil when the color cannot supply a legible hue at all; otherwise the color
// with its brightness nudged into the appearance's window.
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
    CGFloat lo = isDark ? kArtworkDarkBrightnessMin : kArtworkLightBrightnessMin;
    CGFloat hi = isDark ? kArtworkDarkBrightnessMax : kArtworkLightBrightnessMax;
    CGFloat brightness = maxc;
    CGFloat target = MIN(MAX(brightness, lo), hi);
    if (target != brightness) {
        // Scaling the components moves HSB brightness (the max component)
        // while preserving hue and saturation exactly.
        CGFloat scale = target / brightness;
        r *= scale;
        g *= scale;
        b *= scale;
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
    // keeps the White theme's hover identical to the pre-theme one.
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
