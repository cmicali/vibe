//
//  BASSAudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "BASSAudioPlayer.h"
#import "bass.h"
#import "AudioTrack.h"
#import "tags.h"
#import "AudioTrackMetadata.h"

@interface BASSAudioPlayer () {
    HSTREAM _channel;
}

@end

@implementation BASSAudioPlayer {
    NSCache *_metadataCache;
}

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

//    TAGS_Read(0, 0);

}

- (void)dealloc  {
    BASS_Free();
}

// the sync callback
void CALLBACK ChannelEndedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    BASSAudioPlayer *player = (__bridge BASSAudioPlayer *)(user);
}

- (BOOL)play:(AudioTrack *)track {

    [self stop];

    const char *filename = [track.url.path UTF8String];

    _channel = BASS_StreamCreateFile(FALSE, filename, 0, 0, BASS_SAMPLE_FLOAT | BASS_ASYNCFILE) ;
    int code = BASS_ErrorGetCode();
    if (_channel) {
        BASS_ChannelSetSync(_channel, BASS_SYNC_END, 0, ChannelEndedCallback, (__bridge void *)self);
        BASS_ChannelSetAttribute(_channel, BASS_ATTRIB_VOL, 1.0);
        BASS_ChannelPlay(_channel, FALSE);
    }
    code = BASS_ErrorGetCode();

    return code == 0;
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


-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    __block BASSAudioPlayer *weakSelf = self;
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
                [weakSelf->_delegate audioPlayer:self didLoadMetadata:track.url];
            });
        }
    });
}

@end
