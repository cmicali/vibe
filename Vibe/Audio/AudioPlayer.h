//
//  BASSAudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "bass.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AudioPlayerError) {
    AudioPlayerErrorInit = BASS_ERROR_INIT,
    AudioPlayerErrorNotAvail = BASS_ERROR_NOTAVAIL,
    AudioPlayerErrorNoInternet = BASS_ERROR_NONET,
    AudioPlayerErrorInvalidUrl = BASS_ERROR_ILLPARAM,
    AudioPlayerErrorSslUnsupported = BASS_ERROR_SSL,
    AudioPlayerErrorServerTimeout = BASS_ERROR_TIMEOUT,
    AudioPlayerErrorCouldNotOpenFile = BASS_ERROR_FILEOPEN,
    AudioPlayerErrorFileInvalidFormat = BASS_ERROR_FILEFORM,
    AudioPlayerErrorSupportedCodec = BASS_ERROR_CODEC,
    AudioPlayerErrorUnsupportedSampleFormat = BASS_ERROR_SPEAKER,
    AudioPlayerErrorInsufficientMemory = BASS_ERROR_MEM,
    AudioPlayerErrorNo3D = BASS_ERROR_NO3D,
    AudioPlayerErrorUnknown = BASS_ERROR_UNKNOWN
};

@protocol AudioPlayerDelegate;
@class AudioWaveform;

@interface AudioPlayer : NSObject

@property (nullable, weak) id <AudioPlayerDelegate> delegate;
@property NSTimeInterval position;

- (BOOL)play:(AudioTrack *)track;

- (BOOL)isPlaying;

- (BOOL)isPaused;

- (BOOL)isStopped;

- (NSTimeInterval)duration;

- (QWORD)numBytes;

- (DWORD)readAudioSamples:(void *)buffer length:(DWORD)length;

- (AudioWaveform *)audioWaveform;

- (void)loadMetadata:(NSArray<AudioTrack*>*)tracks;

- (NSError * )errorForErrorCode:(AudioPlayerError)erro;

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
