//
//  GaplessSpliceMath.h
//  Vibe
//
//  The gapless auto-advance's arithmetic and gates, as static inlines so the
//  unit tests reach them without compiling AudioPlayer. The mechanism they
//  serve lives in AudioPlayer+Gapless.m (maybeArmGaplessOnQueue and
//  promoteGaplessOnQueue).
//

#import <Foundation/Foundation.h>
#import "FadeMath.h"

// Whether the crossfade setting permits arming the splice: only the declick
// minimum, which the UI presents as crossfade off. A longer setting is a
// request for overlapped transitions, and auto-advance then keeps the
// classic teardown path rather than butt-splicing.
static inline BOOL VibeGaplessArmAllowed(NSInteger crossfadeMilliseconds) {
    return crossfadeMilliseconds <= (NSInteger)kFadeDurationMilliseconds;
}

// A player node's connection format is fixed at connect time, so a queued
// segment must match the current file's sample rate and channel count
// exactly; anything else falls back to the classic transition.
static inline BOOL VibeGaplessFormatsMatch(double sampleRateA, uint32_t channelsA,
                                           double sampleRateB, uint32_t channelsB) {
    return sampleRateA == sampleRateB && channelsA == channelsB;
}

// playerTime.sampleTime is monotonic across queued segments and resets only
// at [node stop], so when the boundary passes, the promoted track's published
// segment start is the old one shifted back by the finished file's length —
// zero or negative, composing across chained promotions. The position
// getter's (segmentStart + sampleTime) math is signed and already correct
// for it.
static inline int64_t VibeGaplessPromotedSegmentStart(int64_t segmentStartFrame,
                                                      int64_t finishedFileLength) {
    return segmentStartFrame - finishedFileLength;
}
