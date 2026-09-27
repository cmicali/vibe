//
//  NowPlayingRules.h
//  Vibe
//
//

#import <Foundation/Foundation.h>
#import "NowPlayingController.h"     // NowPlayingPlaybackState

// isPlaying and isPaused are exclusive (during Loading the intent decides), so
// the branch order carries no meaning.
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

// nil equals nil, or an artistless track republishes every tick. Shared with
// the iOS widget publisher.
static inline BOOL VibeNowPlayingStringsEqual(NSString *_Nullable a, NSString *_Nullable b) {
    return a == b || (b && [a isEqualToString:b]);
}

// Further than this from the system's extrapolation is a jump (a seek, a
// pitch rescale) and republishes.
static const NSTimeInterval kVibeNowPlayingRepublishTolerance = 1.0;

// The system extrapolates elapsed time at the published rate while playing,
// so natural advance is not dirty.
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
