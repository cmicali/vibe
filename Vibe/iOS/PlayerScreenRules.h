//
//  PlayerScreenRules.h
//  Vibe (iOS)
//
//  The player screen's display state, tested from the macOS suite. Separate
//  from the mac's TrackDisplayRules.h: no launch grace here, and parked tracks
//  the mac has no equivalent of.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibePlayerScreenState) {
    VibePlayerScreenStateEmpty,   // no tracks: the open hint and the midline
    VibePlayerScreenStateLoading, // the current track's open is in flight
    VibePlayerScreenStateParked,  // a track is loaded but the player holds nothing
    VibePlayerScreenStateError,   // the current track's play failed
    VibePlayerScreenStateTrack,   // a live playhead: playing, or paused on real audio
};

// ORDER IS THE CONTRACT. Loading and Parked come before Error because in both
// the player's getters serve the outgoing track or zero, so the times must
// rest whatever else is true; a failure on a parked track keeps the park's
// resting times. playerDuration reads 0 while Loading and while nothing is
// open.
static inline VibePlayerScreenState VibeResolvePlayerScreenState(
        NSUInteger trackCount,
        BOOL trackStartPending,
        BOOL parked,
        BOOL hasError,
        NSTimeInterval playerDuration) {
    if (trackCount == 0) {
        return VibePlayerScreenStateEmpty;
    }
    if (trackStartPending) {
        return VibePlayerScreenStateLoading;
    }
    if (parked && playerDuration <= 0) {
        return VibePlayerScreenStateParked;
    }
    if (hasError) {
        return VibePlayerScreenStateError;
    }
    return VibePlayerScreenStateTrack;
}

// 0:00, the metadata's duration and zero progress rather than a playhead.
static inline BOOL VibePlayerScreenRendersRestingTimes(VibePlayerScreenState state) {
    return state == VibePlayerScreenStateLoading || state == VibePlayerScreenStateParked;
}

// What Now Playing publishes. A failed play describes no track: Now Playing
// must not advertise audio that did not start.
static inline BOOL VibePlayerScreenDescribesTrack(VibePlayerScreenState state) {
    return state == VibePlayerScreenStateLoading
            || state == VibePlayerScreenStateParked
            || state == VibePlayerScreenStateTrack;
}

// The strip is the card in one line, so the same question.
static inline BOOL VibeMiniPlayerVisible(VibePlayerScreenState state) {
    return VibePlayerScreenDescribesTrack(state);
}

NS_ASSUME_NONNULL_END
