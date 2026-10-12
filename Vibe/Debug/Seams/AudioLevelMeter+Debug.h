//
//  AudioLevelMeter+Debug.h
//  Vibe
//
//  The render suite's seam for a meter callback stalled between its entry
//  and its publication. Implemented in AudioLevelMeter.m, beside the meter's
//  private struct.
//

#if DEBUG

#import "AudioLevelMeter.h"

@interface AudioLevelMeter (Debug)

// While set, a callback blocks inside VibeLevelMeterRender after it has read
// the session it will publish into; debugRendersHeld counts the callbacks
// blocked there. Any thread.
- (void)debugHoldRender:(BOOL)hold;
- (NSUInteger)debugRendersHeld;

@end

#endif
