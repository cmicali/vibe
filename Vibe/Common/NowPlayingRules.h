//
//  NowPlayingRules.h
//  Vibe
//
//  The republish position rule, kept apart from NowPlayingController so that
//  it is a function of the numbers alone — no info center, no clock of its
//  own.
//

#import <Foundation/Foundation.h>

// A published position further than this from what the system's own
// extrapolation predicts is a jump, from a seek or a pitch rescale, and must
// be republished. Anything inside it is natural playback advance, which the
// system tracks without a republish.
static const NSTimeInterval kVibeNowPlayingRepublishTolerance = 1.0;

// The system Now Playing UI extrapolates the elapsed time itself from the
// last publish: position advances at the published rate while playing, and
// holds while paused or stopped. Natural advance therefore must not count as
// dirty — YES only for a jump the extrapolation cannot explain.
static inline BOOL VibeNowPlayingPositionIsDirty(NSTimeInterval publishedPosition,
                                                 CFAbsoluteTime publishedAt,
                                                 double publishedRate,
                                                 BOOL publishedWasPlaying,
                                                 NSTimeInterval position,
                                                 CFAbsoluteTime now,
                                                 NSTimeInterval tolerance) {
    double extrapolationRate = publishedWasPlaying ? publishedRate : 0.0;
    NSTimeInterval predicted = publishedPosition + (now - publishedAt) * extrapolationRate;
    return fabs(position - predicted) > tolerance;
}
