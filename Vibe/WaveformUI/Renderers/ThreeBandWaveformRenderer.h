//
//  ThreeBandWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

// A DJ player's 3-band display: the low, mid and high bands' levels, each
// band set an antialiased envelope in the theme's bandColors, about the
// midline or grounded.
@interface ThreeBandWaveformRenderer : AudioWaveformRenderer

// Spectrum shares the bands' levels, outline, morph, sides and bake, and fills
// the outline with each bar's mix of the theme's spectrumColors instead.
- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                     spectrum:(BOOL)spectrum;

@end
