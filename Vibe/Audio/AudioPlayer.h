//
//  AudioPlayer.h
//  Vibe
//
//  The playback engine's one public surface, shared by both shells. The
//  player is a transport — play, pause, seek, stop — over its own voice bus
//  (AudioVoiceBus.h) and render pipeline (AudioPlayer+Pipeline.h). It
//  publishes state the moment a verb lands and reports every outcome to its
//  delegate on the main thread; the audio follows within a declick. Each
//  platform's own half is declared beside its implementation:
//  Mac/Devices/AudioPlayer+Devices.h (output devices, bit-perfect output) and
//  iOS/AudioPlayer+Recovery.h (session verdicts).
//

#import <Foundation/Foundation.h>

#import "AudioError.h"     // domain, userInfo key and codes; re-exported here
#import "PlaybackIntent.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;
@class AudioFX;
@class AudioLoadingConfiguration;

@interface AudioPlayer : NSObject

@property (nullable, weak) id <AudioPlayerDelegate> delegate;

// Readonly because the player is the single writer of both. currentTrack
// flips on its own queue, and the requested device id changes only through
// the init and device-switch paths. An external write would desync playback
// state or blind device recovery.
@property (nullable, strong, readonly) AudioTrack* currentTrack;
@property (atomic, readonly)    NSInteger currentlyRequestedAudioDeviceId;

// Turntable-style pitch adjustment in percent, clamped to ±maxPitch. Speed
// and pitch move together, as on a Technics fader; 0 is normal speed. It
// persists across tracks, being a deck control rather than a track property.
@property (nonatomic) float pitch;

// Fader range in percent, 8 by default. Shrinking it re-clamps the current
// pitch.
@property (nonatomic) float maxPitch;

// Track-change crossfade length in milliseconds, 10 (the declick minimum) by
// default. It applies only when a play replaces an audibly playing track —
// first plays, and the pause, seek and stop declicks, always use the minimum
// so transport stays instant. Atomic: the UI writes it, the player queue
// reads it per crossfade. The write also keeps the gapless successor honest:
// raising it past the minimum unqueues a successor already queued on the
// current voice, and lowering it back re-queues the parked next track.
@property (atomic) NSInteger crossfadeMilliseconds;

// What a transport edge does: a play, seek, pause, resume, stop or track
// change. YES, the default: a ≤10 ms declick ramp, touching only those
// frames, so the body of the track and every gapless boundary stay
// sample-exact. NO: a cut, leaving every sample untouched and letting the
// edge click. A crossfade longer than the declick is the user's choice and
// fades either way; bit-perfect output holds the crossfade at the declick,
// so NO applies no gain at all there. Atomic: the UI writes it, the player
// queue reads it per ramp.
@property (atomic) BOOL declick;

// Whether the meter publishes band levels for active equalizer indicators.
// Off by default and demand-driven. The shells enable it only for counted
// indicator demand, modeled output audio and material presentation
// visibility. Setting it applies or drops the render's meter stage on the
// player queue (applyLevelMeterOnQueue), and a rate change re-applies it.
//
// Main thread only, like every other transport-facing setter here.
@property (nonatomic) BOOL levelsEnabled;

// The equalizer indicator's newest coherent band-level snapshot, 0..1. Fills
// `out` with `count` values and returns NO — leaving `out` untouched — when no
// tap is running, which a caller should read as "nothing to show", not as
// silence. `sequence` is monotonic for this player's lifetime and advances for
// every publication, even when the numeric levels did not change. Lock-free
// for the main-thread snapshot poller.
- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence;

// The macOS FX controls exist from init so intent and tempo survive live
// toggles. Audio nodes are created on first enable, then bypassed while off.
// The iOS player has no FX object.
@property (nonatomic, readonly, nullable) AudioFX *fx;

// The render chain as it stands, stage by stage from the source file to the
// output device — each a dictionary with `stage` (source, decode, bus,
// varispeed, fx, meter, output, and on macOS device), `present`, and that
// stage's facts: rates, sample formats, channels, whether it is in the
// render. One queue round trip; any thread but the player queue. What
// Settings > Advanced lists and the debug report saves.
- (NSArray<NSDictionary<NSString *, id> *> *)audioPathSnapshot;

// deviceUID and deviceName name the persisted output device. Empty means follow
// the system default; an unmatched saved device remains pending. Discovery is
// asynchronous and never blocks the player's queue. A match is applied only
// where VibeCanBindSavedOutputDevice allows — Stopped, or Loading while the
// engine is not running; the rule and its trap live on that function
// (AudioPlayer+Devices) — and only committed after the HAL bind succeeds;
// later eligible transitions retry a pending match. enableFX selects the initial FX route; see fx.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate;

// The same, with the saved device's model UID, so a class-compliant interface
// moved to another USB port (and so given a new device UID) is still found at
// launch. macOS passes it; iOS has no saved device and uses the form above.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID
                             name:(NSString *)deviceName enableFX:(BOOL)enableFX
                         delegate:(id <AudioPlayerDelegate>)delegate;

// No settings surface uses this initializer. It is the diagnostic/test seam
// for loading budgets. The player starts with this immutable snapshot, and
// each new underlying file open snapshots its timeout values. A same-row
// replay keeps the open and therefore keeps its snapshot.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID
                              name:(NSString *)deviceName
                          enableFX:(BOOL)enableFX
                          delegate:(id <AudioPlayerDelegate>)delegate
              loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Replaces the immutable snapshot used by future opens and prefetch
// decisions. An open already in flight keeps its timeout snapshot and active
// work is never cancelled. Main-thread callers may use this as a synchronous
// no-UI configuration seam.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

#pragma mark - Transport

- (void)play:(AudioTrack *)track;
// The user's transport action: toggles the state which exists when it reaches
// the player queue, including an in-flight open's landing intent.
- (void)playPause;
// Explicit system verdicts (audio-session and remote-command play/pause).
// Idempotent on the player queue: duplicate notifications cannot accidentally
// toggle playback back to the state the system just asked it to leave.
- (void)pause;
- (void)resume;

// Action-only queue barrier for a structural replacement: the position and
// pause state the player would land in if nothing else arrived, including
// Loading's pending seek and pause intent. Returns NO if stopped or a non-nil
// requested row is no longer current; leaves intent untouched. Do not poll
// it: ordinary UI reads remain lock-only.
- (BOOL)getPlaybackIntent:(VibePendingPlaybackIntent *)intent forTrack:(nullable AudioTrack *)track;

// Starts a track at position (file seconds, clamped), optionally parked:
// with startPaused the track loads but nothing renders until playPause.
// Used for Convert to FLAC's same-audio swap and a playlist replacement that
// must land parked. It always declicks rather than crossfades: crossfading the
// swap would only dip it, while a parked replacement should render nothing.
// Everything else — delegate callbacks and prefetch — is an ordinary play:.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused;

// Moves the playhead, playing or paused, in file seconds (clamped). The move
// is a new voice at the target with the old one fading out beside it, so it
// is instant and click-free; didFinishSeeking: settles it, including a seek
// dropped because the track changed under it or nothing playable was loaded.
- (void)seekToPosition:(NSTimeInterval)position;

// Stops playback and unloads the current track. Any in-flight open is
// superseded, the voice fades to silence, and the player reports Stopped with
// no currentTrack. It fires no transport or track-end callback: this is not a
// track-end event, so it must not drive auto-advance, and the caller owns the
// UI reset.
- (void)stop;

// Ends the current track as if it had played to its end: it stops output and
// notifies the delegate through audioPlayer:didFinishPlaying:. That handler
// drives auto-advance, or the end-of-playlist stop, so the caller needs no
// knowledge of next against stop. Used when a forward skip lands at or past
// the end. A no-op unless a track is playing or paused.
- (void)finishCurrentTrack;

// Pre-opens the track's file so that a later play: of it starts without
// paying for the open, which dominates auto-advance and skip latency. For a
// cloud file it also starts the download early. Call it with the playlist's
// next track whenever a track starts playing; nil drops the parked handle at
// the end of the playlist. It is single-use, consumed by the next play: of
// the same path.
//
// It is also the gapless point: with the crossfade at its minimum (and, under
// bit-perfect output, the next file wanting the device's current format) the
// parked file is queued on the current voice, which continues into it at the
// boundary with no gap — see audioPlayer:didAutoAdvanceFromTrack:toTrack:.
// The track passed here is the one that promote delivers, so it must always
// be the playlist's own next-track object.
- (void)prefetchTrack:(nullable AudioTrack *)track;

// The provider reported the pending open's transfer MOVING. Extends that
// open's abandon deadline, matched against the underlying open request's
// unique identifier rather than its path. A same-row replay preserves that
// identifier; a later open of the same URL gets a new one, so an old monitor
// cannot extend it. Call only from the monitor's uncoalesced positive-movement
// feed, never its whole-percent UI handler.
- (void)noteOpenProgressForOpenRequestIdentifier:(uint64_t)openRequestIdentifier;

#pragma mark - Beta diagnostics

// Records the first UI position beyond each published playing position in
// betas (VIBE_VERBOSE_LOGGING); a no-op otherwise. Main thread.
- (void)noteDisplayedPosition:(NSTimeInterval)position forTrack:(nullable AudioTrack *)track;

@end

// Everything a caller off the player queue may ask the player about itself,
// implemented in AudioPlayer+State.m. It is a category only so the file split
// compiles cleanly; to callers it is simply part of AudioPlayer.
//
// None of these makes a player-queue round trip. Each takes the state lock,
// copies what it needs, and computes off the lock — which is what lets the
// update timer call position several times a second and the refresh funnels
// call the rest on every pass. They are short locked snapshots, not lock-free
// reads: acquiring that lock can briefly wait. They read and never drive:
// nothing here touches the engine or the graph.
@interface AudioPlayer (State)

// Playhead in file seconds: what the current voice has rendered, so it holds
// its value across an engine stop and is readable while the player queue is
// busy. Reads 0 while Stopped or Loading.
@property (readonly) NSTimeInterval position;

// Whether the next track is queued on the current voice for a gapless
// continuation at the boundary. Observability (the debug channel).
@property (readonly, getter=isGaplessArmed) BOOL gaplessArmed;

// Actual modeled output liveness, unlike isPlaying's transport intent:
// Loading is false unless an outgoing crossfade is still audible, while a
// playing voice and every voice still fading out are true. An FX tail
// ringing after the last voice is not modeled here, and never with a timer.
@property (readonly) BOOL outputAudioActive;

// Published transport state: exactly one of these three is true. During
// Loading, isPlaying/isPaused reflect whether the open will land playing or
// parked. A pause reports paused the moment it is requested. An action that
// must order after pending transport uses getPlaybackIntent:forTrack:.
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;
// File-open observability, orthogonal to the transport state above. Position
// and duration read 0 during Loading, meaning unknown rather than zero.
- (BOOL)isLoading;

- (NSTimeInterval)duration;

@end

// Every method is required: the player invokes them all unconditionally,
// with no respondsToSelector: guards at the send sites.
@protocol AudioPlayerDelegate <NSObject>

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer;

// Fires when a play request's file open is still pending after a short grace
// period, as on a slow disk or a downloading cloud placeholder. Show a
// loading state. It is followed by didStartPlaying:, by error:, or, when a
// newer play supersedes the load, by the newer track's events. A superseded
// load gets no terminal callback of its own.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
     didBeginLoading:(AudioTrack *)track
openRequestIdentifier:(uint64_t)openRequestIdentifier;

// Fires when play/pause changes what an in-flight open will do when it lands,
// and when a same-file rebind replaces its playlist row. No audio has started
// or paused yet; use it only to refresh transport and Now Playing state, not
// playback-time accounting.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeLoadingPaused:(BOOL)paused
                  forTrack:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
// track is nil when a seek was requested with nothing playable loaded, as
// right after a failed play. The seek is then a no-op, but the UI still gets
// the callback so it can settle the waveform.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(nullable AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;
// Playback advanced gaplessly into the queued next track: startedTrack — the
// object the delegate handed to prefetchTrack: — is already sounding.
// Advance the playlist index WITHOUT calling play:. A track's end fires
// exactly one of didFinishPlaying: or this, never both.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack;

// macOS only, main thread, sent on EVERY settled device mutation, the id
// moved or not: the shell persists the choice and drives the menu. A fallback
// to System Output (-1) the user did NOT choose — the bound device vanished or
// failed — carries that device's UID and name, so the shell keeps the saved
// preference and the device is re-adopted when it returns; an explicit System
// Output selection carries nil for both and clears it. carriedModesUID names
// the device whose remembered modes an automatic model-match bind read (the
// same interface on another USB port), for the shell to persist that carry;
// nil for every other bind.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputDevice:(NSInteger)newDeviceID
   involuntaryFallbackUID:(nullable NSString *)fallbackUID
  involuntaryFallbackName:(nullable NSString *)fallbackName
      carriedModesFromUID:(nullable NSString *)carriedModesUID;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@optional
// macOS device settings, read on main at submission and on the player queue
// before a bind or mode edit. The provider must support both threads.
// No UI work: the UID can differ from the shell's last settled preference.
// Without this provider the explicit setter arguments remain authoritative.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    outputModesForDeviceUID:(nullable NSString *)deviceUID
          bitPerfectOutput:(BOOL *)bitPerfectOutput
           exclusiveOutput:(BOOL *)exclusiveOutput;

// Main-thread delivery, only when actual modeled output crosses between active
// and inactive. Read outputAudioActive for the current value when refreshing.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputAudioActive:(BOOL)outputAudioActive;

// macOS only, main-thread delivery, only when bitPerfectReport changed. The
// report settles asynchronously after every toggle, play, pause, device
// switch and volume move, so a caller that reads it right after a setter
// sees the previous one; this is the edge to redraw from.
- (void)audioPlayerDidChangeBitPerfectReport:(AudioPlayer *)audioPlayer;

@end

NS_ASSUME_NONNULL_END
