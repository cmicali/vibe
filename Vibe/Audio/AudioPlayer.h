//
//  BASSAudioPlayer.h
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
@class MainPlayerController;

@interface AudioPlayer : NSObject <CoreAudioSystemOutputDeviceDelegate>

@property (nullable, weak) id <AudioPlayerDelegate> delegate;
@property (assign) NSTimeInterval position;
@property (nullable, strong) AudioTrack* currentTrack;

- (id)initWithDevice:(NSInteger)deviceIndex lockSampleRate:(BOOL)lockSampleRate delegate:(MainPlayerController *)delegate;

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

- (NSInteger)currentOutputDeviceIndex;

- (void)setOutputDevice:(NSInteger)outputDeviceIndex;
- (void)setDefaultOutputDevice;

@end

@protocol AudioPlayerDelegate <NSObject>
@optional

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOuputDevice:(NSInteger)newDeviceIndex;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
