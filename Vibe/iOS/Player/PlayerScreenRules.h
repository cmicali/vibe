//
//  PlayerScreenRules.h
//  Vibe (iOS)
//
//  The player screen's display state, tested from the macOS suite. Separate
//  from the mac's TrackDisplayRules.h: no launch grace here, and parked tracks
//  the mac has no equivalent of. Also the card's pager and a scrub's action.
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

// Loading and Parked outrank Error. The player may still describe the outgoing
// track. A parked failure with no duration keeps resting times.
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

// The duration the screens draw: the player's, else the metadata's while
// the player holds none (parked, or opening).
static inline NSTimeInterval VibePlayerScreenDuration(NSTimeInterval playerDuration,
                                                      NSTimeInterval trackDuration) {
    return playerDuration > 0 ? playerDuration : trackDuration;
}

#pragma mark - A scrub

typedef NS_ENUM(NSInteger, VibePlayerScrubAction) {
    VibePlayerScrubActionIgnore,      // no track, or no open and no duration
    VibePlayerScrubActionSeekPlayer,  // the player seeks, by its duration or the metadata's
    VibePlayerScrubActionHold,        // no duration yet: keep the target until metadata lands
    VibePlayerScrubActionOpenParked,  // a parked track: open its file paused at the target
};

// What a scrub does. Parked, the player holds no file, so a scrub opens one
// paused rather than playing. Its duration comes from metadata, and until
// metadata lands the target is held. An open in flight takes the metadata's
// duration and keeps its own play intent.
static inline VibePlayerScrubAction VibePlayerScrubActionFor(NSTimeInterval playerDuration,
                                                             BOOL hasTrack,
                                                             BOOL parked,
                                                             BOOL loading,
                                                             NSTimeInterval trackDuration) {
    if (playerDuration > 0) {
        return VibePlayerScrubActionSeekPlayer;
    }
    if (!hasTrack || !(parked || loading)) {
        return VibePlayerScrubActionIgnore;
    }
    if (trackDuration <= 0) {
        return VibePlayerScrubActionHold;
    }
    return parked ? VibePlayerScrubActionOpenParked : VibePlayerScrubActionSeekPlayer;
}

#pragma mark - The playhead

// The player's position moves a render buffer at a time, about 23 ms. At
// deep zoom that is 2 pt, and a waveform moved by it on each display frame
// judders. So the waveform's position runs on at real time from where it was
// last shown, and moves a tenth of the way to the player's each frame. A miss
// past the snap distance, from a seek, a stall or a track change, jumps to the
// player's. A first frame passes a negative shown position.
static const NSTimeInterval kVibePlayheadSnapSeconds = 0.15;
static const double kVibePlayheadPull = 0.1;
static inline NSTimeInterval VibePlayheadShownPosition(NSTimeInterval shown, NSTimeInterval elapsed,
                                                       NSTimeInterval player) {
    NSTimeInterval running = shown + elapsed;
    NSTimeInterval miss = player - running;
    if (shown < 0 || !(elapsed >= 0) || fabs(miss) > kVibePlayheadSnapSeconds) {
        return player;
    }
    return running + miss * kVibePlayheadPull;
}

#pragma mark - The pager

// The page's own index, so the last page arrives dimmed. Under Repeat All no
// page is last. Under shuffle only the current page knows its next, which the
// playlist answers (currentHasNext).
static inline BOOL VibePlayerPageNextEnabled(NSUInteger index,
                                             NSUInteger currentIndex,
                                             NSUInteger count,
                                             BOOL currentHasNext,
                                             BOOL repeatAll) {
    if (index == currentIndex) {
        return currentHasNext;
    }
    return index + 1 < count || repeatAll;
}

// The pages within radius of the current one, clamped to the playlist. A
// cursor past the end counts as the last page.
static inline NSRange VibePlayerPageWindow(NSUInteger count, NSUInteger currentIndex, NSUInteger radius) {
    if (count == 0) {
        return NSMakeRange(0, 0);
    }
    NSUInteger current = MIN(currentIndex, count - 1);
    NSUInteger first = current > radius ? current - radius : 0;
    NSUInteger last = MIN(current + radius, count - 1);
    return NSMakeRange(first, last - first + 1);
}

NS_ASSUME_NONNULL_END
