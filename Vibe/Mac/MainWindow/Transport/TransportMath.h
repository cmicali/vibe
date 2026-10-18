//
//  TransportMath.h
//  Vibe
//
//  The skip distances and the volume's scroll and key steps, functions of the
//  numbers alone.
//

#import <Foundation/Foundation.h>

// The three skip distances, by level 0, 1 and 2: the base bar count, twice it
// and four times it, or 10, 30 and 60 wall-clock seconds without a tempo. A
// base of 0 is the unset setting and reads as 8.
static inline NSInteger VibeSkipBars(NSInteger baseBars, NSUInteger level) {
    return (baseBars > 0 ? baseBars : 8) << level;
}

static inline NSTimeInterval VibeSkipWallClockSeconds(NSUInteger level) {
    switch (level) {
        case 0: return 10.0;
        case 1: return 30.0;
    }
    return 60.0;
}

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

// The volume an Up or Down press moves, in the slider's 0-1 units. A wheel's
// line moves it as far, and so do ten points of a trackpad's scroll.
static const double kVibeVolumeStep = 0.05;
static const double kVibeScrollPointsPerLine = 10;

// A scroll's volume change. Fingers moving up the trackpad, or a wheel rolled
// away from the user, turn it up under either scrolling direction.
static inline double VibeVolumeScrollDelta(double deltaY, BOOL precise, BOOL inverted) {
    double lines = precise ? deltaY / kVibeScrollPointsPerLine : deltaY;
    return (inverted ? -lines : lines) * kVibeVolumeStep;
}
