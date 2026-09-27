//
//  TransportMath.h
//  Vibe
//
//  The skip-distance arithmetic, a function of the numbers alone.
//

#import <Foundation/Foundation.h>

// In FILE seconds, what the player seeks in. Whole 4/4 bars with a tempo, so
// the jump stays on the grid at any pitch; else WALL-CLOCK seconds converted
// by the rate, so the displayed clock moves by exactly the stated amount.
static inline NSTimeInterval VibeSkipFileSeconds(double bars,
                                                 float bpm,
                                                 NSTimeInterval wallClockSeconds,
                                                 double rate) {
    if (bpm > 0) {
        return bars * 4.0 * 60.0 / bpm;
    }
    return wallClockSeconds * rate;
}
