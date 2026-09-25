//
//  AudioFX+Debug.h
//  Vibe
//
//  The test suites' fault seam for a hosted effect: an Apple unit that has
//  been uninitialized refuses its next render, as one does under a hosting
//  failure. The implementation stays beside the chain, whose struct is
//  private to it; this declaration lives in Debug so the shipping FX API
//  stays minimal.
//

#if DEBUG

#import "AudioFX.h"

@interface AudioFX (Debug)

// Uninitializes the hosted unit at `index` — the units in the order the
// render meets them: the EQ, the reverb and its low-cut, the delays' shared
// low-cut, then each delay's three — so its next render fails; the next
// connect at another format hosts it again. NO with no unit there. Player
// queue.
- (BOOL)debugUninitializeUnitAtIndex:(NSUInteger)index;

@end

#endif
