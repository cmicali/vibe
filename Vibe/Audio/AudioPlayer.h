//
//  BASSAudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioWaveform;

@interface AudioPlayer : NSObject

@property (nullable, weak) id <AudioPlayerDelegate> delegate;
@property NSTimeInterval position;

- (void)rampVolumeToZero:(BOOL)async;

- (void)rampVolumeToNormal:(BOOL)async;

- (BOOL)play:(AudioTrack *)track;

- (BOOL)isPlaying;

- (BOOL)isPaused;

- (BOOL)isStopped;

- (NSTimeInterval)duration;

- (uint64_t)numBytes;

- (uint32_t)readAudioSamples:(void *)buffer length:(uint32_t)length;

- (AudioWaveform *)audioWaveform;

- (void)loadMetadata:(NSArray<AudioTrack*>*)tracks;

- (void)playPause;

- (NSUInteger)numChannels;
@end


@protocol AudioPlayerDelegate <NSObject>
@optional

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didLoadMetadata:(AudioTrack *)track;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishLoadingMetadata:(NSUInteger)numTracks;

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
