//
//  WaveformView+Debug.h
//  Vibe
//
//  Declaration-only: the implementation is in the class's own .mm, which keeps
//  the shipping header free of #if DEBUG.
//

#import "WaveformView.h"

@interface WaveformView (Debug)
// The renderer still eases. A cleared picture keeps its buffers until it
// settles flat, so a resting sample waits for it. Main thread.
- (BOOL)debugWaveformEasing;
@end
