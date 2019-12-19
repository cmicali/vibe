//
//  BASSAudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "bass.h"
#import "AudioTrack.h"
#import "tags.h"
#import "AudioTrackMetadata.h"

@interface AudioPlayer () {
    HSTREAM _channel;
}

@end

@implementation AudioPlayer {
    NSCache *_metadataCache;
    AudioTrack *_currentTrack;
}

static const void * const objectiveBASSQueueKey = "BASSQueue";

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {

    _channel = nil;
    _metadataCache = [[NSCache alloc] init];

    BASS_PluginLoad("libbassflac.dylib", 0);
    BASS_PluginLoad("libtags.dylib", 0);
    if (!BASS_Init(-1, 44100, 0, NULL, NULL)) {
        NSLog(@"Could not initialize BASS");
    }
    BASS_INFO info;
    BASS_GetInfo(&info);
    NSLog(@"Bass init");

}

- (void)dealloc  {
    BASS_Free();
}

// the sync callback
void CALLBACK ChannelEndedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    __block AudioPlayer *player = (__bridge AudioPlayer *)(user);
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        AudioTrack *t = player->_currentTrack;
        [player stop];
        [player->_delegate audioPlayer:player didFinishPlaying:t];
    });
}

- (BOOL)play:(AudioTrack *)track {

    [self stop];

    const char *filename = [track.url.path UTF8String];

    _channel = BASS_StreamCreateFile(FALSE, filename, 0, 0, BASS_SAMPLE_FLOAT | BASS_ASYNCFILE) ;
    __block AudioPlayer *weakSelf = self;
    if (_channel) {

        BASS_ChannelSetSync(_channel, BASS_SYNC_END, 0, ChannelEndedCallback, (__bridge void *)self);
        BASS_ChannelSetAttribute(_channel, BASS_ATTRIB_VOL, 1.0);
        BOOL success = BASS_ChannelPlay(_channel, FALSE);

        if (success) {
            _currentTrack = track;
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [weakSelf->_delegate audioPlayer:self didStartPlaying:track];
            });
        }

        return YES;
    }
    [self stop];
    int code = BASS_ErrorGetCode();
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [weakSelf->_delegate audioPlayer:self error:[weakSelf errorForErrorCode:code]];
    });
    return NO;
}

- (void)pause {
    BASS_ChannelPause(_channel);
}

- (void)resume {
    BASS_ChannelPlay(_channel, NO);
}

- (void)stop {
    if (_channel) {
        BASS_ChannelStop(_channel);
        BASS_StreamFree(_channel);
        _channel = nil;
    }
    _currentTrack = nil;
}

- (BOOL)isPlaying {
    DWORD isPlaying = BASS_ChannelIsActive(_channel);
    return isPlaying == BASS_ACTIVE_PLAYING;
}

- (NSTimeInterval)duration {
    QWORD len = BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
    double time = BASS_ChannelBytes2Seconds(_channel, len);
    return time;
}

- (NSTimeInterval)position  {
    QWORD len = BASS_ChannelGetPosition(_channel, BASS_POS_BYTE);
    double position = BASS_ChannelBytes2Seconds(_channel, len);
    return position;
}

- (void)setPosition:(NSTimeInterval)pos {
    QWORD seekTo = BASS_ChannelSeconds2Bytes(_channel, pos);
    BASS_ChannelSetPosition(_channel, seekTo, BASS_POS_BYTE);
}


-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    __block AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (AudioTrack *track in tracks) {
            if (!track.metadata) {
                if ([weakSelf->_metadataCache objectForKey:track.url]) {
                    track.metadata = [weakSelf->_metadataCache objectForKey:track.url];
                }
                else {
                    track.metadata = [AudioTrackMetadata getMetadataForURL:track.url];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [weakSelf->_delegate audioPlayer:self didLoadMetadata:track];
            });
        }
    });
}

- (NSError *)errorForErrorCode:(AudioPlayerError)erro {
    NSString *str;

    if(erro == AudioPlayerErrorInit)
        str = @"BASS_ERROR_INIT: BASS_Init has not been successfully called.";
    else if(erro == AudioPlayerErrorNotAvail)
        str = @"BASS_ERROR_NOTAVAIL: Only decoding channels (BASS_STREAM_DECODE) are allowed when using the \"no sound\" device. The BASS_STREAM_AUTOFREE flag is also unavailable to decoding channels.";
    else if(erro == AudioPlayerErrorNoInternet)
        str = @"BASS_ERROR_NONET: No internet connection could be opened. Can be caused by a bad proxy setting.";
    else if(erro == AudioPlayerErrorInvalidUrl)
        str = @"BASS_ERROR_ILLPARAM: url is not a valid URL.";
    else if(erro == AudioPlayerErrorSslUnsupported)
        str = @"BASS_ERROR_SSL: SSL/HTTPS support is not available.";
    else if(erro == AudioPlayerErrorServerTimeout)
        str = @"BASS_ERROR_TIMEOUT: The server did not respond to the request within the timeout period, as set with the BASS_CONFIG_NET_TIMEOUT config option.";
    else if(erro == AudioPlayerErrorCouldNotOpenFile)
        str = @"BASS_ERROR_FILEOPEN: The file could not be opened.";
    else if(erro == AudioPlayerErrorFileInvalidFormat)
        str = @"BASS_ERROR_FILEFORM: The file's format is not recognised/supported.";
    else if(erro == AudioPlayerErrorSupportedCodec)
        str = @"BASS_ERROR_CODEC: The file uses a codec that is not available/supported. This can apply to WAV and AIFF files, and also MP3 files when using the \"MP3-free\" BASS version.";
    else if(erro == AudioPlayerErrorUnsupportedSampleFormat)
        str = @"BASS_ERROR_SPEAKER: The sample format is not supported by the device/drivers. If the stream is more than stereo or the BASS_SAMPLE_FLOAT flag is used, it could be that they are not supported.";
    else if(erro == AudioPlayerErrorInsufficientMemory)
        str = @"BASS_ERROR_MEM: There is insufficient memory.";
    else if(erro == AudioPlayerErrorNo3D)
        str = @"BASS_ERROR_NO3D: Could not initialize 3D support.";
    else if(erro == AudioPlayerErrorUnknown)
        str = @"BASS_ERROR_UNKNOWN: Some other mystery problem! Usually this is when the Internet is available but the server/port at the specific URL isn't.";

    return [NSError errorWithDomain:@"com.commonwealthrecordings.Vibe"
                               code:erro
                           userInfo:@{NSLocalizedDescriptionKey: str}];
}

@end
