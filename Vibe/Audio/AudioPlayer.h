//
//  AudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AudioError.h"     // domain, userInfo key and codes; re-exported here

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;
@class AudioDevice;
@class AudioFX;

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

// Whether a tap publishes band levels for the equalizer indicator to follow.
// Off by default, and demand-driven rather than fixed at init like enableFX
// below: it is set from whether anything is both playing and on screen, so the
// tap costs nothing while backgrounded. Setting it installs or removes the tap
// on the player queue, and a media-services rebuild re-installs to match.
//
// Main thread only, like every other transport-facing setter here.
@property (nonatomic) BOOL levelsEnabled;

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

// Starts a track at position (file seconds, clamped), optionally parked:
// with startPaused the track loads but nothing renders until playPause.
// Exists for Convert to FLAC's swap, and therefore always declicks rather
// than crossfades: it replaces a track with the same audio at the same
// position, which a crossfade would only dip. Everything else — crossfade,
// delegate callbacks, prefetch — is an ordinary play:.
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

// prefetchTrack: plus an acknowledgement, delivered once on the main thread,
// that the prefetch's open claim is REGISTERED — or that no claim is needed:
// a nil track, a path already parked, or a path the in-flight play already
// owns. Registration, not admission or completion: the block says the claim
// is visible to any later same-path query, not that the file has begun or
// finished opening, so it cannot be delayed by a parked admission. It is how
// the shell orders "release the background-download hold" after "the
// successor's claim exists", closing the window where the metadata lane and
// the prefetch would each start a transfer of the same file. The
// acknowledgement can arrive after a newer play has re-asserted the hold, so
// its handler must drop it when the track it was issued for is no longer the
// playlist's current one.
- (void)prefetchTrack:(nullable AudioTrack *)track whenClaimed:(nullable void (^)(void))claimed;

// The provider reported the pending open's transfer MOVING. Extends that
// open's abandon deadline (AudioFileOpenRules.h) — and can only extend it,
// never shorten, so feeding a sample is always safe — matched against the
// pending request's path and dropped when none is pending. Call it only on a
// raw increase: a repeated fraction is a stall, and a stalled transfer must
// run out of its budget. The shells feed it from the download monitor's
// UNCOALESCED movement feed, never its whole-percent fraction handler, whose
// gate can stay silent for tens of seconds on a huge slow file moving fine.
- (void)noteOpenProgressForURL:(NSURL *)url;

@end

// Everything a caller off the player queue may ask the player about itself,
// implemented in AudioPlayer+State.m. It is a category only so the file split
// compiles cleanly; to callers it is simply part of AudioPlayer, exactly as
// (Devices) below is.
//
// None of these blocks. Each takes the state lock, copies what it needs, and
// computes off the lock — which is what lets the update timer call position
// several times a second and the refresh funnels call the rest on every pass.
// They read and never drive: nothing here touches the engine, the graph or the
// player queue.
@interface AudioPlayer (State)

// Playhead in file seconds. Lock-free, and reads 0 while Stopped or Loading.
// Seek with seekToPosition:; the move is asynchronous.
@property (readonly) NSTimeInterval position;

// Whether the next track is pre-scheduled on the current node for a gapless
// splice at the boundary. Observability (the debug channel); lock-free.
@property (readonly, getter=isGaplessArmed) BOOL gaplessArmed;

- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;
// The in-flight file open. isPlaying reflects whether it will start playing;
// isPaused reflects a pending parked start. Position and duration read 0 here,
// meaning unknown rather than zero.
- (BOOL)isLoading;

- (NSUInteger)numChannels;
- (NSTimeInterval)duration;

// The equalizer indicator's band levels, 0..1, newest published frame. Fills
// `out` with `count` values and returns NO — leaving `out` untouched — when no
// tap is running, which a caller should read as "nothing to show", not as
// silence. Lock-free, for a caller running at display rate.
- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count;

@end

// The output-device half of the player, implemented in AudioPlayer+Devices.m.
// It is a category only so the file split compiles cleanly; to callers it is
// simply part of AudioPlayer.
@interface AudioPlayer (Devices)

- (NSInteger)currentlyActiveAudioDeviceId;

// outputDeviceID is a CoreAudio AudioDeviceID held as an NSInteger, or -1 to
// follow the system default output. It is not a menu or array index. Device
// IDs do not survive a reboot, so persistence goes by UID and name; see
// initWithDeviceUID:.
- (void)setOutputDevice:(NSInteger)outputDeviceID;

@end

// Every method is required: the player invokes them all unconditionally,
// with no respondsToSelector: guards at the send sites.
@protocol AudioPlayerDelegate <NSObject>

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer;

// A play has been accepted and is about to be submitted to the player queue.
// SYNCHRONOUS, on play:'s calling thread — main at every call site — and
// strictly before the open can start, which is what makes it the shell's
// provider-bandwidth edge: acquire the background-download hold here, before
// the foreground open contends with anything the hold suspends. Fired for
// every play — fast local files, parked-prefetch fast paths, and same-file
// rebinds included, where the hold is briefly held and promptly released by
// the play's own settlement. The handler must not block and must not call
// back into the player.
- (void)audioPlayer:(AudioPlayer *)audioPlayer willSubmitPlayForTrack:(AudioTrack *)track;

// Fires when a play request's file open is still pending after a short grace
// period, as on a slow disk or a downloading cloud placeholder. Show a
// loading state. It is followed by didStartPlaying:, by error:, or, when a
// newer play supersedes the load, by the newer track's events. A superseded
// load gets no terminal callback of its own.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track;

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

@end

NS_ASSUME_NONNULL_END
