//
//  ThreeBandWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "WaveformRenderer.h"

// Nested low, mid and high envelopes in the theme’s bandColors.
@interface ThreeBandWaveformRenderer : WaveformRenderer
@end

// Shares 3-Band’s geometry; fills it with per-bar mixes of spectrumColors.
@interface SpectrumWaveformRenderer : ThreeBandWaveformRenderer
@end
