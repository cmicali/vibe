//
//  NowPlayingRules.h
//  Vibe
//
//  What to publish, and when — kept apart from NowPlayingController so that
//  both are functions of the numbers alone: no info center, no player, no
//  clock of their own.
//

#import <Foundation/Foundation.h>
#import "NowPlayingController.h"     // NowPlayingPlaybackState

// The player's two state questions, mapped to what the system distinguishes.
// They are mutually exclusive by construction — during Loading it is the
// pending start intent that decides which answers YES, not the state alone
// (see AudioPlayer's isPlaying/isPaused) — so this is total and the branch
// order carries no meaning. An ordinary load therefore reads Playing, a parked
// one Paused, which is what the enum's own doc describes.
static inline NowPlayingPlaybackState VibeNowPlayingStateForPlayer(BOOL isPlaying,
                                                                   BOOL isPaused) {
    if (isPlaying) {
        return NowPlayingPlaybackStatePlaying;
    }
    if (isPaused) {
        return NowPlayingPlaybackStatePaused;
    }
    return NowPlayingPlaybackStateStopped;
}

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
