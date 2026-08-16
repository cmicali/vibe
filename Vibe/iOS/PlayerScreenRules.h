//
//  PlayerScreenRules.h
//  Vibe (iOS)
//
//  The player screen's display state and the resolution that picks one, as a
//  function of the flags rather than of the view controller, so it can be
//  reasoned about — and tested — on its own. Header-only, Foundation-only.
//
//  The mac twin is Vibe/Mac/MainWindow/TrackDisplayRules.h. The two enums are
//  deliberately separate: this screen has no launch grace, and it parks tracks
//  (a relaunch restore, the end of the playlist, a media-services reset) that
//  the mac window has no equivalent of, so one shared enum would carry states
//  neither platform resolves.
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

// ORDER IS THE CONTRACT. After Empty come the two states that describe what
// the PLAYER is holding — an open in flight, or nothing at all — because in
// both the position and duration getters serve the outgoing track or zero, so
// the times must render at rest whatever else is true. Error describes the
// last *attempt* and is therefore the fallback for a track the player would
// otherwise be running: a failure that lands on a parked track leaves the
// park's resting times up, which is what the screen did before this rule
// existed.
//
// playerDuration is the live getter, which reads 0 while Loading and while
// nothing is open.
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

// Whether the time labels and the waveform show the track at rest — 0:00 and
// the full duration, progress pinned to zero — rather than a live playhead.
// Loading: the player's getters still serve the OUTGOING track. Parked: it
// holds nothing at all, so the duration has to come from metadata.
static inline BOOL VibePlayerScreenRendersRestingTimes(VibePlayerScreenState state) {
    return state == VibePlayerScreenStateLoading || state == VibePlayerScreenStateParked;
}

// Whether the screen is describing a track at all — what the Now Playing card
// publishes, and what the debug channel reports as the displayed track. Empty
// has none, and a failed play describes no track either: the error text takes
// the header, and the card must not keep advertising audio that did not start.
static inline BOOL VibePlayerScreenDescribesTrack(VibePlayerScreenState state) {
    return state == VibePlayerScreenStateLoading
            || state == VibePlayerScreenStateParked
            || state == VibePlayerScreenStateTrack;
}

// Whether the mini player stands above the tab bar. It is the same question as
// the one above — the strip is the card in one line, so it appears exactly
// when there is a track to name and disappears with the playlist. Error is
// deliberately excluded with it: a failed play describes no track, and a strip
// naming audio that did not start is worse than no strip.
static inline BOOL VibeMiniPlayerVisible(VibePlayerScreenState state) {
    return VibePlayerScreenDescribesTrack(state);
}

NS_ASSUME_NONNULL_END
