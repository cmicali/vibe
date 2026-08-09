//
//  TrackDisplayController.h
//  Vibe
//
//  Owns the track-display rendering for the main window: the artist and title
//  labels, with the title's shrink-to-fit, the time labels, the codec and BPM
//  corner labels, the empty-state drop hint, and the waveform view's rendering
//  states — progress, loading shimmer and empty placeholder. It is pure
//  rendering, on a decide-against-draw split: MainPlayerController resolves
//  what to show, as a TrackDisplayState plus a track and times, and this
//  object draws it. It reads no player or playlist state and never decides a
//  state transition.
//
//  It is one of the two display controllers, with ArtworkDisplayController,
//  that render into MainPlayerContentView's widgets. The content view builds
//  and owns the hierarchy, each display controller adopts its subset at init
//  and renders one facet, and MainPlayerController decides what they render.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class CodableAudioWaveform;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// Which performance effects are currently on, for the header's FX indicators,
// drawn inline at the head of the codec line; see renderFXState:. It mirrors
// the AudioFX flags, since the display controller reads no player state itself.
typedef struct {
    BOOL lowKill;       // Q — low-kill high-pass
    BOOL lowKillBoost;  // W — doubles Q's cutoff (renders as the filled dial)
    BOOL reverb;        // E
    BOOL delay;         // R — 1/8-note echo
    BOOL shortDelay;    // T — 1/16-note echo
} VibeFXDisplayState;

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

// The resolution itself, as a function of the flags rather than of the
// controller, so it can be reasoned about — and tested — on its own.
// MainPlayerController's displayState is the only caller; it reads the inputs
// off its collaborators and every consumer routes through the result. Writing
// a label without consulting it is how a stale time gets composited over the
// error placeholder.
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
    // slow cloud opens and instant on prefetched ones. Stopped is excluded,
    // since an idle player at the end of the playlist legitimately parks on
    // the playlist's last track.
    if (!playerIsStopped && playerTrack != currentTrack) {
        return TrackDisplayStateLoading;
    }
    return playerIsLoading ? TrackDisplayStateLoading : TrackDisplayStateTrack;
}

// Main thread only.
@interface TrackDisplayController : NSObject

// Adopts the header labels and the waveform view from the content view.
// MainPlayerContentView keeps ownership of the view hierarchy.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// A full render of the header for a resolved state. track is the track the
// header should describe: the displayed track for Track and Loading, the
// errored track for Error, whose title goes under the error status, and nil
// for Empty and LaunchGrace. duration is the player's file-time duration, and
// rate is the varispeed playback rate the time labels divide by. errorStatus
// is the artist-line status for the Error state, and nil falls back to
// "Playback error".
- (void)renderState:(TrackDisplayState)state
              track:(nullable AudioTrack *)track
           duration:(NSTimeInterval)duration
               rate:(double)rate
        errorStatus:(nullable NSString *)errorStatus;

// The 3 Hz position tick: waveform progress plus a change-guarded elapsed
// label. duration is the caller's cached track duration, because the live
// player duration reads 0 in the Loading gap. It renders only in Track and
// Loading; the empty and error states keep showing --:--.
- (void)renderPosition:(NSTimeInterval)position
              duration:(NSTimeInterval)duration
                  rate:(double)rate
                 state:(TrackDisplayState)state;

// A change-guarded refresh of the right-hand time label alone, showing either
// the total duration or the remaining time, per the persisted mode. It serves
// the fader-drag path, where the full renderState — let alone the caller's
// full updateUI — is too heavy to run per tick. Like renderPosition: it
// renders only in Track; the loading, empty and error states keep showing
// --:--.
- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate state:(TrackDisplayState)state;

// The BPM line under the codec label. It takes the pitch-scaled display value,
// since the caller owns both the tag-against-analysis precedence and the rate
// scaling. A value of 0 or less clears it.
- (void)renderBPM:(float)displayBPM;

// SF Symbols for the effects that are on, drawn immediately left of the codec
// text, on the same line, so they inherit its right alignment, color and 50%
// alpha. Nothing is drawn for an effect that is off. This is independent of
// the track, because FX persist across tracks, so the codec line is composed
// from the last rendered text and the last rendered FX state, whichever
// changed.
- (void)renderFXState:(VibeFXDisplayState)state;

// The title's shrink-to-fit is computed against the label's width, and the
// label is width-flexible, so re-run the fit for the current text after a
// window resize has changed that width. It is a no-op otherwise: no text is
// measured when the width is unchanged. It works both ways, re-shrinking when
// narrowed and restoring toward the full font when widened.
- (void)refitTitleIfWidthChanged;

// End-of-playlist parking: pin the finished track's header at its start, with
// progress 0, an elapsed time of 0:00 and the right label at the full
// duration. The caller's didFinishPlaying: explains why the resting values
// cannot be read off the player. duration is the finished track's own
// file-time duration.
- (void)resetPlayheadToStartWithDuration:(NSTimeInterval)duration rate:(double)rate;

// The waveform rendering states, forwarded to the view, which stays a plain
// surface. The cache, its deliveries and the style selection stay with the
// controller.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;
- (void)showWaveformLoadingIndicator;
- (void)hideWaveformLoadingIndicator;
// Convert to FLAC's brush-through-the-waveform progress; 0 resets the front.
// The getter serves the debug state dump.
- (void)setConvertSweepFraction:(double)fraction;
- (double)convertSweepFraction;

// The rendered fields, exposed for the debug command channel's state dump; see
// MainPlayerController+Debug.h and DebugUtil.
@property (weak, readonly) NSTextField *artistTextField;
@property (weak, readonly) NSTextField *titleTextField;
@property (weak, readonly) NSTextField *totalTimeTextField;
@property (weak, readonly) NSTextField *currentTimeTextField;
@property (weak, readonly) NSTextField *fileMetadataTextField;

@end

NS_ASSUME_NONNULL_END
