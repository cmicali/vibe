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

@property (assign)              NSTimeInterval position;
@property (nullable, strong)    AudioTrack* currentTrack;
@property (atomic) NSInteger    currentlyRequestedAudioDeviceId;

// Turntable-style pitch adjustment in percent (clamped to ±maxPitch): speed
// and pitch move together, like a Technics pitch fader. 0 = normal speed.
// Persists across tracks (it's a deck control, not a track property).
@property (nonatomic) float pitch;

// Fader range in percent (default 8). Shrinking it re-clamps the current pitch.
@property (nonatomic) float maxPitch;

// The DJ performance effects (low kill/boost, reverb and delay sends, the
// delay's tempo feed) — see AudioFX.h. Non-nil from init, so callers can set
// intent immediately; the graph work lands once the async engine init runs.
@property (nonatomic, readonly) AudioFX *fx;

// deviceUID/deviceName: the persisted output device (empty or unmatched →
// follow the system default). Resolved inside the async init on the player's
// own queue — resolution enumerates CoreAudio devices, which must stay off
// the launch path's main thread.
- (id)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate;

- (void)play:(AudioTrack *)track;
- (void)playPause;

// Ends the current track as if it had played to its end: stops output and
// notifies the delegate via audioPlayer:didFinishPlaying:. The delegate's
// handler is what drives auto-advance (or the end-of-playlist stop), so the
// caller needs no next-vs-stop knowledge — used when a forward skip lands at
// or past the end. No-op unless a track is playing or paused.
- (void)finishCurrentTrack;

// Pre-opens the track's file so a later play: of it starts without paying
// the open — the dominant auto-advance/skip latency (and for cloud files it
// starts the download early). Call with the playlist's next track whenever
// playback of a track starts; nil drops the parked handle (end of playlist).
// Single-use: consumed by the next play: of the same path.
- (void)prefetchTrack:(nullable AudioTrack *)track;

- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isStopped;

- (NSUInteger)numChannels;
- (NSTimeInterval)duration;

- (NSInteger)currentlyActiveAudioDeviceId;

// outputDeviceID is a CoreAudio AudioDeviceID (as NSInteger), or -1 to follow
// the system default output — not a menu/array index. Device IDs are transient
// across reboots; persistence goes by UID/name (see initWithDeviceUID:).
- (void)setOutputDevice:(NSInteger)outputDeviceID;

@end

// All methods are required: the player invokes every one of them
// unconditionally (no respondsToSelector: guards on the send sites).
@protocol AudioPlayerDelegate <NSObject>

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer;

// Fired when a play request's file open is still pending after a short grace
// period (slow disk, cloud placeholder downloading) — show a loading state.
// Always followed by either didStartPlaying: or error:.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
// track is nil when a seek was requested with nothing playable loaded
// (e.g. right after a failed play) — the seek is a no-op but the UI still
// gets the callback to settle the waveform.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(nullable AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
