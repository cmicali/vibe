//
//  NSColor+OKLCH.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Perceptual (OKLCH) clamping for artwork-derived colors. OKLab lightness is
// hue-independent, unlike HSB brightness: a yellow and a blue at the same HSB
// brightness differ wildly in perceived lightness, which is exactly the
// failure mode when clamping a tint that must keep contrast with content
// drawn over it (the header wash under the waveform, the playlist accent).
@interface NSColor (OKLCH)

// Converts to OKLCh, clamps L into [minL, maxL] and C to at most maxC, and
// converts back at `alpha`. A clamped result outside the sRGB gamut reduces
// chroma until it fits — hue and lightness are what the clamp promises to
// preserve. Returns the receiver (at `alpha`) if it can't be read as RGB.
- (NSColor *)vibe_colorByClampingOKLCHLightnessMin:(CGFloat)minL
                                      lightnessMax:(CGFloat)maxL
                                         chromaMax:(CGFloat)maxC
                                             alpha:(CGFloat)alpha;

@end

NS_ASSUME_NONNULL_END
