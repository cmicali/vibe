//
//  ThreeBandWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioWaveformRenderer.h"

// A DJ player's 3-band display: the low, mid and high bands' levels on one
// mirrored axis, in fixed colors with their overlaps tinted.
@interface ThreeBandWaveformRenderer : AudioWaveformRenderer

// 3-Band Smooth: each band's envelope as one antialiased outline through the
// bars, where 3-Band draws pixel-snapped columns.
- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark
                       smooth:(BOOL)smooth;

@end
