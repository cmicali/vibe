//
//  TrackDisplayRules.h
//  Vibe
//
//  The header's display states and the resolution that picks one.
//
//  The iOS twin is Vibe/iOS/PlayerScreenRules.h, deliberately separate: one
//  shared enum would carry states each platform never resolves.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TrackDisplayState) {
    TrackDisplayStateTrack,       // a track is loaded (playing/paused)
    TrackDisplayStateLoading,     // the current track's open is still in flight
    TrackDisplayStateEmpty,       // no track: the drop-hint empty state
    TrackDisplayStateLaunchGrace, // empty, but a launch-time open may be resolving
    TrackDisplayStateError,       // play failed: error text over the track title
    // The header only, never the playback: a notice over whatever the state
    // below it shows, which plays on. A link that failed to open is one.
    // VibeResolveTrackDisplayState never answers it.
    TrackDisplayStateNotice,
};

// Every header write routes through the result; a label written without it
// composites a stale time over the error placeholder. The tracks are compared
// by identity only, never messaged.
static inline TrackDisplayState VibeResolveTrackDisplayState(
        AudioTrack *_Nullable currentTrack,     // what the playlist says is current
        AudioTrack *_Nullable playerTrack,      // what the player is actually on
        AudioTrack *_Nullable erroredTrack,     // the track whose play last failed
        BOOL emptyStateSuppressed,
        BOOL playerIsStopped,
        BOOL playerIsLoading) {
    if (!currentTrack) {
        return emptyStateSuppressed ? TrackDisplayStateLaunchGrace : TrackDisplayStateEmpty;
    }
    // Gated on Stopped so a retry lifts the mask at once.
    if (currentTrack == erroredTrack && playerIsStopped) {
        return TrackDisplayStateError;
    }
    // Until didStartPlaying the player's track, position and duration still
    // describe the PREVIOUS file, so the gap renders Loading rather than
    // composite new tags over old times. Stopped does not exempt it: a change
    // from the end-of-playlist park still reads Stopped here. The park itself
    // is not the gap: the player parks on the track it finished.
    if (playerTrack != currentTrack) {
        return TrackDisplayStateLoading;
    }
    return playerIsLoading ? TrackDisplayStateLoading : TrackDisplayStateTrack;
}

// Placeholder states retain their labels; a parked track's zero duration
// must not overwrite the full-length right label installed at track end.
static inline BOOL VibeTrackTimeMayUpdate(TrackDisplayState state, NSTimeInterval duration, BOOL rightLabel) {
    return state == TrackDisplayStateTrack && (!rightLabel || duration > 0);
}

NS_ASSUME_NONNULL_END
