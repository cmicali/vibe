//
//  AudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;
@class AudioDevice;
@class AudioFX;

extern NSString *const kVibeAudioErrorDomain;

typedef NS_ENUM(NSInteger, VibeAudioErrorCode) {
    VibeAudioErrorFileOpenFailed = 1,
    VibeAudioErrorEngineStartFailed,
    VibeAudioErrorDeviceUnavailable,
    VibeAudioErrorNotPlaying,
    VibeAudioErrorFileOpenTimedOut,
};

@interface AudioPlayer : NSObject

@property (nullable, weak) id <AudioPlayerDelegate> delegate;

// Playhead in file seconds. Lock-free, and reads 0 while Stopped or Loading.
// Seek with seekToPosition:; the move is asynchronous.
@property (readonly)            NSTimeInterval position;
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

// The DJ performance effects: low kill and its boost, the reverb and delay
// sends, and the delay's tempo feed. See AudioFX.h. Non-nil from init, so a
// caller can set intent immediately; the graph work lands once the async
// engine init runs.
@property (nonatomic, readonly) AudioFX *fx;

// deviceUID and deviceName name the persisted output device. Empty or
// unmatched means follow the system default. The async init resolves them on
// the player's own queue, because resolution enumerates CoreAudio devices and
// that must stay off the launch path's main thread.
- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate;

- (void)play:(AudioTrack *)track;
- (void)playPause;

// Starts a track at position (file seconds, clamped), optionally parked:
// with startPaused the track loads but nothing renders until playPause.
// Exists for Convert to FLAC's swap. Everything else — crossfade, delegate
// callbacks, prefetch — is an ordinary play:, which is this with (0, NO).
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused;

// Asynchronous declicked seek, in file seconds, clamped to the file.
// position reports the old playhead until the seek lands, and
// didFinishSeeking: marks completion.
- (void)seekToPosition:(NSTimeInterval)position;

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
- (void)prefetchTrack:(nullable AudioTrack *)track;

- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;
// The in-flight file open; isPlaying also reports YES in this state.
// position and duration read 0 here, meaning unknown rather than zero.
- (BOOL)isLoading;

- (NSUInteger)numChannels;
- (NSTimeInterval)duration;

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

// Fires when a play request's file open is still pending after a short grace
// period, as on a slow disk or a downloading cloud placeholder. Show a
// loading state. It is followed by didStartPlaying:, by error:, or, when a
// newer play supersedes the load, by the newer track's events. A superseded
// load gets no terminal callback of its own.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
// track is nil when a seek was requested with nothing playable loaded, as
// right after a failed play. The seek is then a no-op, but the UI still gets
// the callback so it can settle the waveform.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(nullable AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
