//
//  NSColor+OKLCH.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// OKLCH clamping for artwork-derived colors: OKLab lightness is hue-independent,
// where a yellow and a blue at one HSB brightness differ wildly.
@interface NSColor (OKLCH)

// Clamps L into [minL, maxL] and C to maxC. Out of gamut, chroma gives way,
// never hue or lightness. The receiver at `alpha` if it has no RGB reading.
- (NSColor *)vibe_colorByClampingOKLCHLightnessMin:(CGFloat)minL
                                      lightnessMax:(CGFloat)maxL
                                         chromaMax:(CGFloat)maxC
                                             alpha:(CGFloat)alpha;

@end

NS_ASSUME_NONNULL_END
