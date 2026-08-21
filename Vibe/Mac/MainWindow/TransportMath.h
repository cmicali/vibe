//
//  TransportMath.h
//  Vibe
//
//  The skip-distance arithmetic, kept apart from the transport actions in
//  MainPlayerController+Transport so that it is a function of the numbers
//  alone — no controller, no collaborators.
//

#import <Foundation/Foundation.h>

// How far a skip moves the playhead, in FILE seconds, which is what the
// player seeks in.
//
// With a known tempo the skip moves by whole bars of four beats. That is a
// fixed span of file time, so the jump stays on the musical grid whatever the
// pitch. Without a tempo the fallback is a fixed WALL-CLOCK distance — the
// seconds the user reads off the time label — converted to file time by the
// same varispeed rate the labels divide by, so that the displayed clock
// advances by exactly the stated amount at any pitch.
static inline NSTimeInterval VibeSkipFileSeconds(double bars,
                                                 float bpm,
                                                 NSTimeInterval wallClockSeconds,
                                                 double rate) {
    if (bpm > 0) {
        return bars * 4.0 * 60.0 / bpm;
    }
    return wallClockSeconds * rate;
}
