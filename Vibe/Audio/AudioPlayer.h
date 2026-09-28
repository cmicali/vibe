//
//  AudioPlayer.h
//  Vibe
//
//  The playback engine's public surface, shared by both shells: a transport
//  over its own voice bus and render pipeline. It publishes state the moment a
//  verb lands and reports every outcome to its delegate on main; the audio
//  follows within a declick. The platform halves are
//  Mac/Devices/AudioPlayer+Devices.h and iOS/AudioPlayer+Recovery.h.
//

#import <Foundation/Foundation.h>

#import "AudioError.h"     // domain, userInfo key and codes; re-exported here
#import "PlaybackIntent.h"
#import "AudioResampler.h"  // VibeResampler

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;
@class AudioFX;
@class AudioLoadingConfiguration;

@interface AudioPlayer : NSObject

@property (nullable, weak) id <AudioPlayerDelegate> delegate;

// The player is the single writer of both.
@property (nullable, strong, readonly) AudioTrack* currentTrack;
@property (atomic, readonly)    NSInteger currentlyRequestedAudioDeviceId;

// Turntable pitch in percent, clamped to ±maxPitch: speed and pitch move
// together; 0 is normal speed. Persists across tracks.
@property (nonatomic) float pitch;

// Fader range in percent, 8 by default. Shrinking it re-clamps pitch.
@property (nonatomic) float maxPitch;

// Track-change crossfade in milliseconds, default the 10 ms declick minimum.
// Applies only when a play replaces an audibly playing track. Raising it past
// the minimum unqueues a gapless successor; lowering it re-queues the park.
@property (atomic) NSInteger crossfadeMilliseconds;

// What a transport edge does. YES (default): a ≤10 ms declick touching only
// those frames. NO: a cut, every sample untouched. A longer crossfade fades
// either way; under bit-perfect output the crossfade is held at the declick,
// so NO applies no gain at all.
@property (atomic) BOOL declick;

// The output volume, 0..1, the fader's position: the render's last stage,
// after the meter, whose gain is its cube so the travel reads as loudness.
// 1, the default, leaves every sample untouched; 0 is silence.
@property (atomic) float volume;

// Which resampler converts a file at another rate than the output's: r8brain
// (the default, under evaluation: docs/future/resampler.md) or Apple's, each
// at its highest quality. Applies to conversions begun after the write.
@property (atomic) VibeResampler resampler;

// Whether the meter publishes band levels; the shells enable it only for
// counted indicator demand, modeled output audio and material visibility.
// Main thread only.
@property (nonatomic) BOOL levelsEnabled;

// The newest coherent band-level snapshot, 0..1. NO, `out` untouched, when no
// meter session is publishing: "nothing to show", not silence. `sequence`
// advances with every publication for the player's lifetime. Lock-free.
- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence;

// Exists from init on both platforms so intent and tempo survive toggles;
// its units are hosted at the first connect, and the segment is in the
// render only while wanted.
@property (nonatomic, readonly) AudioFX *fx;

// The setting's live effect on iOS: off clears every stage's intent at
// submission, then reconnects the pipeline with the output stopped and puts
// a playing track back. The mac applies the same setting through its device
// rebuild (setBitPerfectOutput:exclusiveOutput:enableFX:allowAnyDevice:).
// Any thread.
- (void)setFXEnabled:(BOOL)enabled;

// The render chain stage by stage (audioPathOnQueue). One queue round trip;
// any thread but the player queue.
- (NSArray<NSDictionary<NSString *, id> *> *)audioPathSnapshot;

// deviceUID and deviceName name the persisted output device; empty follows
// the system default, and an unmatched one stays pending. Discovery never
// blocks the player queue; a match binds only where
// VibeCanBindSavedOutputDevice (OutputFormatRules.h) allows, commits only
// after the bind succeeds, and later eligible transitions retry it.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate;

// With the saved device's model UID, so an interface moved to another USB
// port (a new device UID) is still found. macOS only.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID
                             name:(NSString *)deviceName enableFX:(BOOL)enableFX
                         delegate:(id <AudioPlayerDelegate>)delegate;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// For future opens and prefetch decisions; an open in flight keeps its
// timeout snapshot.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

#pragma mark - Transport

- (void)play:(AudioTrack *)track;
// The user's toggle, of the state when it reaches the player queue,
// including an in-flight open's landing intent.
- (void)playPause;
// The system's verdicts: idempotent, so a duplicate notification cannot
// toggle playback back.
- (void)pause;
- (void)resume;

// A queue barrier for a structural replacement: the position and pause state
// the player would land in, Loading's pending intent included. NO, intent
// untouched, if stopped or a non-nil `track` is no longer current. Never
// poll it.
- (BOOL)getPlaybackIntent:(VibePendingPlaybackIntent *)intent forTrack:(nullable AudioTrack *)track;

// Starts a track at position (file seconds, clamped), optionally parked. For
// Convert to FLAC's same-audio swap and a replacement that must land parked;
// always declicks, never crossfades. Otherwise an ordinary play:.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused;

// File seconds, clamped, playing or paused. didFinishSeeking: settles every
// seek, one dropped because the track changed or nothing was loaded included.
- (void)seekToPosition:(NSTimeInterval)position;

// Unloads the current track, superseding any in-flight open. Fires no
// transport or track-end callback, so it never drives auto-advance; the
// caller owns the UI reset.
- (void)stop;

// Ends the current track as if it had played out, through didFinishPlaying:,
// which decides advance or stop. For a forward skip past the end; a no-op
// unless a track is playing or paused.
- (void)finishCurrentTrack;

// Pre-opens the playlist's next track so a later play: of its path skips the
// open (and starts a cloud download early); nil drops the park. Single-use.
// It is also the gapless point: when gapless is allowed the parked file is
// queued on the current voice. The promote delivers this very object, so it
// must be the playlist's own next track.
- (void)prefetchTrack:(nullable AudioTrack *)track;

// The pending open's transfer moved: extends its abandon deadline, matched by
// open identifier, never path, so an old monitor cannot extend a later open.
// Call only from the monitor's uncoalesced movement feed, never its UI handler.
- (void)noteOpenProgressForOpenRequestIdentifier:(uint64_t)openRequestIdentifier;

#pragma mark - Beta diagnostics

// Beta builds only (VIBE_VERBOSE_LOGGING); a no-op otherwise. Main thread.
- (void)noteDisplayedPosition:(NSTimeInterval)position forTrack:(nullable AudioTrack *)track;

@end

// None of these makes a player-queue round trip: each is a short snapshot
// under the state lock, which can briefly wait.
@interface AudioPlayer (State)

// File seconds the current voice has rendered, so it holds across an output
// stop. 0 while Stopped or Loading.
@property (readonly) NSTimeInterval position;

// Whether a gapless successor is queued on the current voice.
@property (readonly, getter=isGaplessArmed) BOOL gaplessArmed;

// Modeled output liveness, unlike isPlaying's intent: a playing voice or one
// still fading out. An FX tail after the last voice is not modeled.
@property (readonly) BOOL outputAudioActive;

// Nothing has started the output since its last idle stop settled: no render
// is pulling the pipeline, an FX tail included. NO from every start attempt,
// a failed one too, until the idle stop that follows it.
@property (readonly) BOOL outputIdle;

// Exactly one is true. During Loading, whether the open will land playing or
// parked. A pause reports paused the moment it is requested.
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;
// Orthogonal to the three above. Position and duration read 0 (unknown)
// during Loading.
- (BOOL)isLoading;

- (NSTimeInterval)duration;

@end

// Every method is required: the player invokes them all unconditionally,
// with no respondsToSelector: guards at the send sites.
@protocol AudioPlayerDelegate <NSObject>

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer;

// A play's open is still pending after a short grace period. Followed by
// didStartPlaying: or error:; a superseded load gets no terminal callback.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
     didBeginLoading:(AudioTrack *)track
openRequestIdentifier:(uint64_t)openRequestIdentifier;

// Play/pause changed what an in-flight open will land as, or a same-file
// rebind replaced its row. No audio has changed: refresh transport and Now
// Playing only, never playback-time accounting.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeLoadingPaused:(BOOL)paused
                  forTrack:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
// track is nil for a seek with nothing playable loaded; still delivered so
// the UI can settle.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(nullable AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;
// startedTrack, the object handed to prefetchTrack:, is already sounding:
// advance the playlist WITHOUT play:. A track's end fires exactly one of
// didFinishPlaying: or this.
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

// Main thread, only when outputAudioActive changes.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputAudioActive:(BOOL)outputAudioActive;

// Main thread, when outputIdle becomes YES: the idle stop has stopped the
// output, any FX tail rung out. Read outputIdle before acting on it; a newer
// start may already own the output.
- (void)audioPlayerOutputDidBecomeIdle:(AudioPlayer *)audioPlayer;

// macOS, main thread, only when bitPerfectReport changed. The report settles
// asynchronously, so a read right after a setter sees the previous one; redraw
// from this edge.
- (void)audioPlayerDidChangeBitPerfectReport:(AudioPlayer *)audioPlayer;

@end

NS_ASSUME_NONNULL_END
