//
//  TrackDisplayController.h
//  Vibe
//
//  Owns the track-display rendering for the main window: the artist/title
//  labels (with the title's shrink-to-fit), the time labels, the codec and
//  BPM corner labels, the empty-state drop hint, and the waveform view's
//  rendering states (progress, loading shimmer, empty placeholder). Pure
//  rendering, split decide-vs-draw: MainPlayerController resolves WHAT to
//  show (TrackDisplayState + track + times) and this object draws it — it
//  reads no player or playlist state and never decides state transitions.
//
//  One of the two display controllers (with ArtworkDisplayController) that
//  render into MainPlayerContentView's widgets: the content view builds and
//  owns the hierarchy, each display controller adopts its subset at init and
//  renders one facet, and MainPlayerController decides what they render.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class CodableAudioWaveform;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// Which performance effects are currently on, for the header's FX indicators
// (drawn inline at the head of the codec line — see renderFXState:). Mirrors
// the AudioFX flags; the display controller reads no player state itself.
typedef struct {
    BOOL lowKill;       // Q — low-kill high-pass
    BOOL lowKillBoost;  // W — doubles Q's cutoff (renders as the filled dial)
    BOOL reverb;        // E
    BOOL delay;         // R — 1/8-note echo
    BOOL shortDelay;    // T — 1/16-note echo
} VibeFXDisplayState;

// The five states the track display can render, resolved in one place
// (MainPlayerController's displayState) so updateUI, updatePlaybackUI, and
// the Now Playing publish all see the same world instead of re-deriving it
// from the underlying flags.
typedef NS_ENUM(NSInteger, TrackDisplayState) {
    TrackDisplayStateTrack,       // a track is loaded (playing/paused)
    TrackDisplayStateLoading,     // the current track's open is still in flight
    TrackDisplayStateEmpty,       // no track: the drop-hint empty state
    TrackDisplayStateLaunchGrace, // empty, but a launch-time open may be resolving
    TrackDisplayStateError,       // play failed: error text over the track title
};

// Main thread only.
@interface TrackDisplayController : NSObject

// Adopts the header labels and the waveform view from the content view; the
// view hierarchy stays owned by MainPlayerContentView.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// Full render of the header for a resolved state. track is the track the
// header should describe: the displayed track for Track/Loading, the errored
// track for Error (its title goes under the error status), nil for
// Empty/LaunchGrace. duration is the player's file-time duration; rate the
// varispeed playback rate the time labels divide by. errorStatus is the
// artist-line status for the Error state (nil falls back to "Playback error").
- (void)renderState:(TrackDisplayState)state
              track:(nullable AudioTrack *)track
           duration:(NSTimeInterval)duration
               rate:(double)rate
        errorStatus:(nullable NSString *)errorStatus;

// The 3 Hz position tick: waveform progress + change-guarded elapsed label.
// duration is the caller's cached track duration (the live player duration
// reads 0 in the Loading gap). Renders only in Track/Loading — the empty and
// error states keep showing --:--.
- (void)renderPosition:(NSTimeInterval)position
              duration:(NSTimeInterval)duration
                  rate:(double)rate
                 state:(TrackDisplayState)state;

// Change-guarded refresh of the right-hand time label alone (total duration,
// or remaining time per the persisted mode) — the fader-drag path, where the
// full renderState (let alone the caller's full updateUI) is too heavy to
// run per tick.
- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate;

// The BPM line under the codec label. Takes the pitch-scaled display value
// (the caller owns tag-vs-analysis precedence and rate scaling); <= 0 clears.
- (void)renderBPM:(float)displayBPM;

// SF Symbols for the effects that are ON, drawn immediately left of the codec
// text (same line, so they inherit its right alignment, color, and 50%
// alpha); nothing is drawn for an effect that is off. Independent of the
// track — FX persist across tracks — so the codec line is composed from the
// last-rendered text and the last-rendered FX state, whichever changed.
- (void)renderFXState:(VibeFXDisplayState)state;

// End-of-playlist parking: pin the finished track's header at its start
// (progress 0, elapsed 0:00, right label at the full duration) — see the
// caller's didFinishPlaying: for why the resting values can't be read off
// the player. duration is the finished track's own (file-time) duration.
- (void)resetPlayheadToStartWithDuration:(NSTimeInterval)duration rate:(double)rate;

// Waveform rendering states, forwarded to the view (which stays a dumb
// surface). The cache, its deliveries, and style selection stay with the
// controller.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;
- (void)showWaveformLoadingIndicator;
- (void)hideWaveformLoadingIndicator;

// The rendered fields, exposed for the debug command channel's state dump
// (MainPlayerController+Debug.h / DebugUtil).
@property (weak, readonly) NSTextField *artistTextField;
@property (weak, readonly) NSTextField *titleTextField;
@property (weak, readonly) NSTextField *totalTimeTextField;
@property (weak, readonly) NSTextField *currentTimeTextField;
@property (weak, readonly) NSTextField *fileMetadataTextField;

@end

NS_ASSUME_NONNULL_END
