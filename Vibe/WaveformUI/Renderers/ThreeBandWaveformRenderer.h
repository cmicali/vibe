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
@end

// A DJ deck's spectrum display. It keeps 3-Band's levels, outline, morph,
// sides and bake. It fills the outline with each bar's mix of the theme's
// spectrumColors in place of the band layers.
@interface SpectrumWaveformRenderer : ThreeBandWaveformRenderer
@end
