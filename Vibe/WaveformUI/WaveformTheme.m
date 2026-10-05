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

// The hover highlight's required luminance separation from the played color.
static const CGFloat kHoverLuminanceDelta = 0.25;

// The built-in themes' resting levels. The colored themes pair a full-alpha
// hue with Sonic Cirrus's bright monochrome unplayed level, on every style.
static const CGFloat kMonochromePlayedAlpha = 0.75;
static const CGFloat kMonochromeUnplayedAlpha = 0.375;
static const CGFloat kColoredUnplayedAlpha = 0.89;

// The album-art legibility clamp; below the saturation floor the color is
// effectively gray and falls back to mono. Perceptual luminance, not HSB
// brightness, which is hue-blind: pure blue reads B=1.0 yet is far too dark.
static const CGFloat kArtworkSaturationFloor = 0.15;
static const CGFloat kArtworkDarkMinLuminance = 0.55;
static const CGFloat kArtworkLightMaxLuminance = 0.45;

// Toward the color's own luminance gray, which leaves the clamp above intact.
static const CGFloat kArtworkUnplayedDesaturation = 0.5;

// 3-Band's seven fills from its three bands, in the layer order. Shaded, the
// CDJ's way: low with mid is the mid shaded, and wherever the highs join they
// are tinted toward what they join, further on light, where the highs are
// dark; the CDJ palette of hdelplan/three-band-waveform follows this within
// 13/255. Unshaded, Engine DJ's way: each band painted whole over the ones
// below, the highs letting about 6% of what they cover through. The bands
// arrive opaque (AppTheme stores them so), and the blends are.
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

// Rekord Bin's bands, shaded: iOS's always, and a mac theme's until it sets
// its own (AppTheme's unset band wells are these).
static NSArray<VibeColor *> *VibeDefaultBandColors(BOOL isDark) {
    static NSArray<VibeColor *> *colors[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger dark = 0; dark < 2; dark++) {
            colors[dark] = VibeBandColors(VibeColorFromHexString(@"0055E1"),
                                          VibeColorFromHexString(dark ? @"FFA600" : @"D97706"),
                                          VibeColorFromHexString(dark ? @"FFFFFF" : @"262626"), YES, dark);
        }
    });
    return colors[isDark ? 1 : 0];
}

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
        _bandColors = VibeDefaultBandColors(isDark);
        CGFloat pr, pg, pb, ur, ug, ub;
        // Alphas aside on purpose: the scrubber's single-bitmap fast path
        // recovers the level difference from unplayedOverPlayedOpacity.
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

#if TARGET_OS_OSX
+ (WaveformTheme *)themeForAppTheme:(AppTheme *)theme isDark:(BOOL)isDark
                       artworkColor:(VibeColor *)artworkColor {
    // 3-Band's hues are its bands, so its played side, which the hover and the
    // volume bar read, is Mono's rather than the hidden waveform color's.
    BOOL bands = [WaveformRendererRegistry readsBandsForIdentifier:theme.waveformStyle];
    WaveformTheme *resolved = [self themeForIdentifier:bands ? SETTINGS_VALUE_WAVEFORM_THEME_MONO : theme.waveformTheme
                                                isDark:isDark
                                          artworkColor:artworkColor
                                          customPlayed:[theme colorForBase:kVibeThemeColorWaveformPlayed dark:isDark]
                                        customUnplayed:[theme colorForBase:kVibeThemeColorWaveformUnplayed dark:isDark]];
    resolved.flatFill = !theme.waveformGradient;
    // Unset and shaded keeps the init's cached default, which a well drag
    // resolves several times a tick.
    if (bands && (!theme.waveformShadeOverlaps || [theme colorForBase:kVibeThemeColorWaveformLow dark:isDark]
                  || [theme colorForBase:kVibeThemeColorWaveformMid dark:isDark]
                  || [theme colorForBase:kVibeThemeColorWaveformHigh dark:isDark])) {
        resolved.bandColors = VibeBandColors([theme displayColorForBase:kVibeThemeColorWaveformLow dark:isDark],
                                             [theme displayColorForBase:kVibeThemeColorWaveformMid dark:isDark],
                                             [theme displayColorForBase:kVibeThemeColorWaveformHigh dark:isDark],
                                             theme.waveformShadeOverlaps, isDark);
    }
    if (theme.waveformPlayheadLine) {
        resolved.playheadColor = [theme displayColorForBase:kVibeThemeColorWaveformPlayhead dark:isDark];
    }
    return resolved;
}
#endif

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

+ (VibeColor *)color:(VibeColor *)color desaturatedBy:(CGFloat)amount {
    CGFloat r, g, b;
    if (!VibeGetRGB(color, &r, &g, &b)) {
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
    if (!VibeGetRGB(played, &r, &g, &b)) {
        return isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    }
    // Toward the contrast pole just far enough to clear the delta (closed form:
    // luminance is linear in the blend). Full alpha whatever the played level:
    // the highlight is the brightest thing in the waveform.
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
