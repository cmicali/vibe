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
