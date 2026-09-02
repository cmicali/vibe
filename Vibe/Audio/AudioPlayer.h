//
//  AudioPlayer.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "AudioError.h"     // domain, userInfo key and codes; re-exported here

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;
@class AudioDevice;
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
// reads it per crossfade. The write also keeps the gapless splice honest:
// raising it past the minimum unqueues an armed next-track segment, and
// lowering it back re-arms parked material.
@property (atomic) NSInteger crossfadeMilliseconds;

// Whether a tap publishes band levels for active equalizer indicators. Off by
// default and demand-driven rather than fixed at init like enableFX below. The
// shells enable it only for counted indicator demand, modeled output audio and
// material presentation visibility. Setting it installs or removes the tap on
// the player queue, and a media-services rebuild re-installs to match.
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

// The DJ performance effects: low kill and its boost, the reverb and delay
// sends, and the delay's tempo feed. See AudioFX.h. With enableFX it is
// non-nil from init, so a caller can set intent immediately; the graph work
// lands once the async engine init runs. Without enableFX it is nil for the
// player's lifetime — no FX node is ever created or attached, the main mixer
// wires straight to the output, and every fx message is a safe no-op —
// which is how the macOS FX-off setting and the FX-less iOS app run.
@property (nonatomic, readonly, nullable) AudioFX *fx;

// deviceUID and deviceName name the persisted output device. Empty means follow
// the system default; an unmatched saved device remains pending. Discovery is
// asynchronous and never blocks the player's queue. A match is applied only
// while Stopped and only committed after the HAL bind succeeds; later Stopped
// transitions retry a pending match. enableFX decides for the player's lifetime
// whether the FX graph segment exists at all; see fx.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate;

// No settings surface uses this initializer. It is the diagnostic/test seam
// for loading budgets. The player starts with this immutable snapshot, and
// each new underlying file open snapshots its timeout values. A same-row
// replay keeps the open and therefore keeps its snapshot.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID
                              name:(NSString *)deviceName
                          enableFX:(BOOL)enableFX
                          delegate:(id <AudioPlayerDelegate>)delegate
              loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Replaces the immutable snapshot used by future opens and prefetch
// decisions. An open already in flight keeps its timeout snapshot and active
// work is never cancelled. Main-thread callers may use this as a synchronous
// no-UI configuration seam.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

- (void)play:(AudioTrack *)track;
// The user's transport action: toggles the state which exists when it reaches
// the player queue, including an in-flight open's landing intent.
- (void)playPause;
// Explicit system verdicts (audio-session and remote-command play/pause).
// Idempotent on the player queue: duplicate notifications cannot accidentally
// toggle playback back to the state the system just asked it to leave. Resume
// also cancels a pause whose short fade-out has not completed yet.
- (void)pause;
- (void)resume;

// Action-only coordination read for a structural replacement. Unlike the
// lock-only UI predicates below, this waits for transport commands already
// submitted to the player queue, including a pause fade which has begun but
// not completed. Do not poll it; main-thread actions call it once before
// committing the model edit that must preserve that ordered intent.
- (BOOL)playingIntentAfterPendingCommands;

// Starts a track at position (file seconds, clamped), optionally parked:
// with startPaused the track loads but nothing renders until playPause.
// Used for Convert to FLAC's same-audio swap and a playlist replacement that
// must land parked. It always declicks rather than crossfades: crossfading the
// swap would only dip it, while a parked replacement should render nothing.
// Everything else — delegate callbacks and prefetch — is an ordinary play:.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused;

// Seeking is AudioPlayer+Seek.h, declared where it is implemented.

// Stops playback and unloads the current track. Any in-flight open is
// superseded, a playing node fades to silence before teardown, and the player
// then reports Stopped with no currentTrack. It fires no delegate callback:
// this is not a track-end event, so it must not drive auto-advance, and the
// caller owns the UI reset.
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
// It is also the gapless arm point: with the crossfade off and the next
// file's format matching the current one, the player pre-schedules the
// prefetched track on the current node and splices at the boundary instead
// of tearing down — see audioPlayer:didAutoAdvanceFromTrack:toTrack:. The
// track passed here is the one that promote delivers, so it must always be
// the playlist's own next-track object.
- (void)prefetchTrack:(nullable AudioTrack *)track;

// The provider reported the pending open's transfer MOVING. Extends that
// open's abandon deadline, matched against the underlying open request's
// unique identifier rather than its path. A same-row replay preserves that
// identifier; a later open of the same URL gets a new one, so an old monitor
// cannot extend it. Call only from the monitor's uncoalesced positive-movement
// feed, never its whole-percent UI handler.
- (void)noteOpenProgressForOpenRequestIdentifier:(uint64_t)openRequestIdentifier;

@end

// Everything a caller off the player queue may ask the player about itself,
// implemented in AudioPlayer+State.m. It is a category only so the file split
// compiles cleanly; to callers it is simply part of AudioPlayer, exactly as
// (Devices) below is.
//
// None of these makes a player-queue round trip. Each takes the state lock,
// copies what it needs, and computes off the lock — which is what lets the
// update timer call position several times a second and the refresh funnels
// call the rest on every pass. They are short locked snapshots, not lock-free
// reads: acquiring that lock can briefly wait. They read and never drive:
// nothing here touches the engine or the graph.
@interface AudioPlayer (State)

// Playhead in file seconds. Reads 0 while Stopped or Loading.
// Seek with seekToPosition:; the move is asynchronous.
@property (readonly) NSTimeInterval position;

// Whether the next track is pre-scheduled on the current node for a gapless
// splice at the boundary. Observability (the debug channel).
@property (readonly, getter=isGaplessArmed) BOOL gaplessArmed;

// Actual modeled output liveness, unlike isPlaying's transport intent:
// Loading is false unless an outgoing crossfade is still audible, while a
// playing node and every tracked retired fade are true. FX wet-tail liveness
// is not exposed by AVAudioEngine and is therefore not guessed here.
@property (readonly) BOOL outputAudioActive;

// Published transport state: exactly one of these three is true. During
// Loading, isPlaying/isPaused reflect whether the open will land playing or
// parked. A pause keeps reporting playing through its short fade. An action
// that must order after pending transport uses playingIntentAfterPendingCommands.
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;
// File-open observability, orthogonal to the transport state above. Position
// and duration read 0 during Loading, meaning unknown rather than zero.
- (BOOL)isLoading;

- (NSTimeInterval)duration;

@end

// The output-device half of the player, implemented in AudioPlayer+Devices.m —
// the macOS-only CoreAudio HAL layer, so the declaration is guarded too: an
// unguarded shared caller would compile on iOS and crash at runtime. It is a
// category only so the file split compiles cleanly; to callers it is simply
// part of AudioPlayer.
#if TARGET_OS_OSX
@interface AudioPlayer (Devices)

// outputDeviceID is a CoreAudio AudioDeviceID held as an NSInteger, or -1 to
// follow the system default output. It is not a menu or array index. Device
// IDs do not survive a reboot, so persistence goes by UID and name; see
// initWithDeviceUID:.
- (void)setOutputDevice:(NSInteger)outputDeviceID;

@end
#endif

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
// Playback advanced gaplessly into the pre-scheduled next track: startedTrack
// — the object the delegate handed to prefetchTrack: — is already sounding.
// Advance the playlist index WITHOUT calling play:. A track's end fires
// exactly one of didFinishPlaying: or this, never both.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@optional
// Main-thread delivery, only when actual modeled output crosses between active
// and inactive. Read outputAudioActive for the current value when refreshing.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputAudioActive:(BOOL)outputAudioActive;

@end

NS_ASSUME_NONNULL_END
