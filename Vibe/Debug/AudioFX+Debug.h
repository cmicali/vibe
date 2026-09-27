//
//  AudioFX+Debug.h
//  Vibe
//
//  The test suites' fault seam for a hosted effect: an uninitialized Apple
//  unit refuses its next render, as under a hosting failure. Implemented in
//  AudioFX.m, beside the chain's private struct.
//

#if DEBUG

#import "AudioFX.h"

@interface AudioFX (Debug)

// Uninitializes the hosted unit at `index` (render order: the EQ, the reverb
// and its low-cut, the delays' shared low-cut, then each delay's three) so its
// next render fails; the next connect at another format hosts it again. NO
// with no unit there. Player queue.
- (BOOL)debugUninitializeUnitAtIndex:(NSUInteger)index;

@end

#endif
