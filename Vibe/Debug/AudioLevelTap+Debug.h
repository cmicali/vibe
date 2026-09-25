//
//  AudioLevelTap+Debug.h
//  Vibe
//
//  The render suite's seam for a meter callback stalled between its entry
//  and its publication. The implementation stays beside the meter, whose
//  struct is private to it; this declaration lives in Debug so the shipping
//  tap API stays minimal.
//

#if DEBUG

#import "AudioLevelTap.h"

@interface AudioLevelTap (Debug)

// While set, a callback blocks inside VibeLevelMeterRender after it has read
// the session it will publish into; debugRendersHeld counts the callbacks
// blocked there. Any thread.
- (void)debugHoldRender:(BOOL)hold;
- (NSUInteger)debugRendersHeld;

@end

#endif
