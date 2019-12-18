//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

#include <atomic>

#include <SFBAudioEngine/AudioPlayer.h>
#include <SFBAudioEngine/AudioDecoder.h>
#include <SFBAudioEngine/AudioMetadata.h>

#define UPDATE_HZ 3

enum ePlayerFlags : unsigned int {
    ePlayerFlagRenderingStarted			= 1u << 0,
    ePlayerFlagRenderingFinished		= 1u << 1,
    ePlayerFlagDecodingStarted  		= 1u << 2,
    ePlayerFlagDecodingFinished	    	= 1u << 3
};

@interface AudioPlayer () {
@private
    SFB::Audio::Player	*_player;		// The player instance
    std::atomic_uint	_playerFlags;
    dispatch_source_t	_timer;
}
@end

@implementation AudioPlayer {
    NSCache *_metadataCache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        try {
            _player = new SFB::Audio::Player();
            _metadataCache = [[NSCache alloc] init];
        }
        catch(const std::exception& e) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setAlertStyle:NSAlertStyleCritical];
            [alert setMessageText:@"Unable to create audio player"];
            [alert addButtonWithTitle:@"OK"];
            /* response = */ [alert runModal];
            return nil;
        }

        _playerFlags = 0;

//        _player->SetRingBufferCapacity(256 * 1024 * 1024);

        // This will be called from the realtime rendering thread and as such MUST NOT BLOCK!!
        _player->SetRenderingStartedBlock(^(const SFB::Audio::Decoder& /*decoder*/){
            self->_playerFlags.fetch_or(ePlayerFlagRenderingStarted);
        });
        //
        // This will be called from the realtime rendering thread and as such MUST NOT BLOCK!!
        _player->SetRenderingFinishedBlock(^(const SFB::Audio::Decoder& /*decoder*/){
            self->_playerFlags.fetch_or(ePlayerFlagRenderingFinished);
        });

        _player->SetDecodingStartedBlock(^(const SFB::Audio::Decoder &decoder) {
            self->_playerFlags.fetch_or(ePlayerFlagDecodingStarted);
        });

        _player->SetDecodingFinishedBlock(^(const SFB::Audio::Decoder &decoder) {
            self->_playerFlags.fetch_or(ePlayerFlagDecodingFinished);
        });

        // Update the UI 5 times per second
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / UPDATE_HZ, NSEC_PER_SEC / 3);

        dispatch_source_set_event_handler(_timer, ^{
            [self timerHandler];
        });

        // Start the timer
        dispatch_resume(_timer);

    }

    return self;
}

- (void) dealloc {
    delete _player;
    _player = nullptr;
}

- (void) timerHandler {

    auto flags = self->_playerFlags.load();

    NSURL *url = (__bridge NSURL *) self->_player->GetPlayingURL();

    if(ePlayerFlagRenderingStarted & flags) {
        self->_playerFlags.fetch_and(~ePlayerFlagRenderingStarted);
        [self.delegate audioPlayer:self didStartRenderingURL:url];
        return;
    }
    else if(ePlayerFlagRenderingFinished & flags) {
        self->_playerFlags.fetch_and(~ePlayerFlagRenderingFinished);
        [self.delegate audioPlayer:self didFinishRenderingURL:url];
        return;
    }
    else if(ePlayerFlagDecodingStarted & flags) {
        self->_playerFlags.fetch_and(~ePlayerFlagDecodingStarted);
        [self.delegate audioPlayer:self didStartDecodingURL:url];
        return;
    }
    else if(ePlayerFlagDecodingFinished & flags) {
        self->_playerFlags.fetch_and(~ePlayerFlagDecodingFinished);
        [self.delegate audioPlayer:self didFinishDecodingURL:url];
        return;
    }

    [self updateStats];

    [self.delegate audioPlayer:self didMakePlaybackProgress:url];

}

- (void)updateStats {
    if(self->_player->GetPlaybackPositionAndTime(_currentFrame, _totalFrames, _currentTime, _totalTime)) {
        self.fractionComplete = static_cast<float>(_currentFrame) / static_cast<float>(_totalFrames);
    }
}

- (BOOL) playURL:(NSURL *)url {
     __block AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL playing = weakSelf->_player->Play((__bridge CFURLRef)url);
        [self updateStats];
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [weakSelf.delegate audioPlayer:weakSelf didStartPlayingURL:url didPlay:playing];
        });
    });
    return YES;
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
                [weakSelf->_delegate audioPlayer:self didLoadMetadata:track.url];
            });
        }
    });
}

- (void)playPause {
    _player->PlayPause();
}

- (void)stop {
    _player->Stop();
}

- (void)seek:(float)position {
    _player->SeekToPosition(position);
}

- (bool)supportsSeeking {
    return _player->SupportsSeeking();
}
@end
