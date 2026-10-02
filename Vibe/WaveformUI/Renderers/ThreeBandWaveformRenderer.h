//
//  ThreeBandWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

// A DJ player's 3-band display: the low, mid and high bands' levels on one
// mirrored axis, each band set an antialiased envelope in fixed colors with
// their overlaps tinted.
@interface ThreeBandWaveformRenderer : AudioWaveformRenderer

@end
