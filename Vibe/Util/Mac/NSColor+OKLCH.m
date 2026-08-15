//
//  NSColor+OKLCH.m
//  Vibe
//

#import "NSColor+OKLCH.h"

// sRGB <-> OKLab, Björn Ottosson's reference matrices
// (https://bottosson.github.io/posts/oklab/).

typedef struct { double L, a, b; } VibeOKLab;

static double srgbToLinear(double c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

static double linearToSRGB(double c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

static VibeOKLab oklabFromSRGB(double r, double g, double b) {
    r = srgbToLinear(r); g = srgbToLinear(g); b = srgbToLinear(b);
    double l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    double m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    double s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return (VibeOKLab){
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

// Returns whether the result landed inside the sRGB gamut, before clipping.
static BOOL srgbFromOKLab(VibeOKLab lab, double *outR, double *outG, double *outB) {
    double l = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
    double m = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
    double s = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
    l = l * l * l; m = m * m * m; s = s * s * s;
    double r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    double g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    double b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    static const double kGamutEps = 1e-4;
    BOOL inGamut = r >= -kGamutEps && r <= 1 + kGamutEps &&
                   g >= -kGamutEps && g <= 1 + kGamutEps &&
                   b >= -kGamutEps && b <= 1 + kGamutEps;
    *outR = linearToSRGB(MIN(1.0, MAX(0.0, r)));
    *outG = linearToSRGB(MIN(1.0, MAX(0.0, g)));
    *outB = linearToSRGB(MIN(1.0, MAX(0.0, b)));
    return inGamut;
}

@implementation NSColor (OKLCH)

- (NSColor *)vibe_colorByClampingOKLCHLightnessMin:(CGFloat)minL
                                      lightnessMax:(CGFloat)maxL
                                         chromaMax:(CGFloat)maxC
                                             alpha:(CGFloat)alpha {
    NSColor *rgb = [self colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) {
        return [self colorWithAlphaComponent:alpha];
    }
    VibeOKLab lab = oklabFromSRGB(rgb.redComponent, rgb.greenComponent, rgb.blueComponent);
    double L = MIN((double)maxL, MAX((double)minL, lab.L));
    double C = MIN((double)maxC, hypot(lab.a, lab.b));
    double hue = atan2(lab.b, lab.a); // radians; gray (C≈0) keeps whatever atan2 says — chroma 0 makes it moot

    double r, g, b;
    if (!srgbFromOKLab((VibeOKLab){L, C * cos(hue), C * sin(hue)}, &r, &g, &b)) {
        // Out of gamut at this lightness and hue, so binary-search the largest
        // chroma that fits. A chroma of 0, pure gray, always fits at any L in
        // [0,1].
        double lo = 0, hi = C;
        for (int i = 0; i < 12; i++) {
            double mid = (lo + hi) / 2;
            if (srgbFromOKLab((VibeOKLab){L, mid * cos(hue), mid * sin(hue)}, &r, &g, &b)) {
                lo = mid;
            }
            else {
                hi = mid;
            }
        }
        srgbFromOKLab((VibeOKLab){L, lo * cos(hue), lo * sin(hue)}, &r, &g, &b);
    }
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:alpha];
}

@end
