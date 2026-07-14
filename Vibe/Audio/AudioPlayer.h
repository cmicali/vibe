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

// deviceUID/deviceName: the persisted output device (empty or unmatched →
// follow the system default). Resolved inside the async init on the player's
// own queue — resolution enumerates CoreAudio devices, which must stay off
// the launch path's main thread.
- (id)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate;

- (void)play:(AudioTrack *)track;
- (void)playPause;

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

- (void)setOutputDevice:(NSInteger)outputDeviceIndex;

@end

@protocol AudioPlayerDelegate <NSObject>
@optional

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

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceIndex;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
