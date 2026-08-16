//
//  TrackDisplayRules.h
//  Vibe
//
//  The header's five display states and the resolution that picks one, as a
//  function of the flags rather than of the controller, so it can be reasoned
//  about — and tested — on its own. Header-only; TrackDisplayController.h
//  imports it for the enum its rendering methods take.
//
//  The iOS twin is Vibe/iOS/PlayerScreenRules.h. The two enums are deliberately
//  separate: that screen has no launch grace and parks tracks the mac never
//  does, so one shared enum would carry states neither platform resolves.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

// The five states the track display can render. MainPlayerController's
// displayState resolves them in one place, so that updateUI, updatePlaybackUI
// and the Now Playing publish all see the same world rather than re-deriving
// it from the underlying flags.
typedef NS_ENUM(NSInteger, TrackDisplayState) {
    TrackDisplayStateTrack,       // a track is loaded (playing/paused)
    TrackDisplayStateLoading,     // the current track's open is still in flight
    TrackDisplayStateEmpty,       // no track: the drop-hint empty state
    TrackDisplayStateLaunchGrace, // empty, but a launch-time open may be resolving
    TrackDisplayStateError,       // play failed: error text over the track title
};

// The resolution itself. MainPlayerController's displayState is the only
// caller; it reads the inputs off its collaborators and every consumer routes
// through the result. Writing a label without consulting it is how a stale
// time gets composited over the error placeholder.
//
// The track arguments are compared by identity only, never messaged.
static inline TrackDisplayState VibeResolveTrackDisplayState(
        AudioTrack *_Nullable currentTrack,     // what the playlist says is current
        AudioTrack *_Nullable playerTrack,      // what the player is actually on
        AudioTrack *_Nullable erroredTrack,     // the track whose play last failed
        BOOL emptyStateSuppressed,
        BOOL playerIsStopped,
        BOOL playerIsLoading) {
    if (!currentTrack) {
        // Launch grace: a launch-time open may still be resolving, so render a
        // blank header instead of flashing the empty state.
        return emptyStateSuppressed ? TrackDisplayStateLaunchGrace : TrackDisplayStateEmpty;
    }
    // Gated on stopped so that a retry's Loading or Playing state instantly
    // lifts the error mask.
    if (currentTrack == erroredTrack && playerIsStopped) {
        return TrackDisplayStateError;
    }
    // A just-initiated track change is still queued on the player's serial
    // queue: the player's currentTrack — and its position and duration — still
    // describe the PREVIOUS file, because currentTrack flips to the new track
    // only at didStartPlaying. Render the gap as Loading so the new track's
    // tags are never composited over the old file's times; it is visible on
    // slow cloud opens and instant on prefetched ones. Stopped does not
    // exempt the gap: play flips the player's state asynchronously, so a
    // change initiated from the end-of-playlist park still reads Stopped
    // here. The park itself is not the gap, because an idle player parks on
    // the track it just finished — playerTrack == currentTrack.
    if (playerTrack != currentTrack) {
        return TrackDisplayStateLoading;
    }
    return playerIsLoading ? TrackDisplayStateLoading : TrackDisplayStateTrack;
}

NS_ASSUME_NONNULL_END
