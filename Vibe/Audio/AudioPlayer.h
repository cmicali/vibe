//
//  AudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "CoreAudioUtil.h"

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

@interface AudioPlayer : NSObject <CoreAudioSystemOutputDeviceDelegate>

@property (nullable, weak) id <AudioPlayerDelegate> delegate;

@property (assign)              NSTimeInterval position;
@property (nullable, strong)    AudioTrack* currentTrack;
@property (atomic) NSInteger    currentlyRequestedAudioDeviceId;

- (id)initWithDevice:(NSString *)deviceName lockSampleRate:(BOOL)lockSampleRate delegate:(id <AudioPlayerDelegate>)delegate;

- (BOOL)lockSampleRate;
- (void)setLockSampleRate:(BOOL)lockSampleRate;

- (void)play:(AudioTrack *)track;
- (void)playPause;
//- (void)rampVolumeToZero:(BOOL)async;
//- (void)rampVolumeToNormal:(BOOL)async;

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
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOuputDevice:(NSInteger)newDeviceIndex;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
