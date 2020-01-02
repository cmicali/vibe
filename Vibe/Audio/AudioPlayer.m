//
//  BASSAudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "BassWrapper.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveform.h"
#import "Util.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import "BassUtil.h"

#define PLAYBACK_RATE   44100

@interface AudioPlayer () <BASSChannelDelegate>
@end

@implementation AudioPlayer {
    AudioTrack *_currentTrack;
    NSInteger _selectedAudioDevice;
    HSTREAM _channel;
    BOOL _lockSampleRate;
}

#pragma mark - Init

- (id)initWithDevice:(NSInteger)deviceIndex lockSampleRate:(BOOL)lockSampleRate {
    self = [super init];
    if (self) {
        _selectedAudioDevice = deviceIndex;
        _lockSampleRate = lockSampleRate;
        [self setup];
    }
    return self;
}

- (void)setup {

    _channel = 0;

    BASS_PluginLoad("libbassflac.dylib", 0);

    BASS_SetConfig(BASS_CONFIG_FLOATDSP, 1);

    if (!BASS_Init((int)_selectedAudioDevice, PLAYBACK_RATE, 0, NULL, NULL)) {
        DDLogError(@"Error initializing BASS");
    }
    BASS_INFO info;
    BASS_GetInfo(&info);

    LogDebug(@"BASS init");
    LogDebug(@"  freq: %d latency: %d minrate: %d maxrate: %d flags: %d", info.freq, info.latency, info.minrate, info.maxrate, info.flags);

    [CoreAudioUtil listenForSystemOutputDeviceChanges:self];
}

- (void)dealloc  {
    [self stop];
    BASS_Free();
    DDLogDebug(@"Bass freed");
}

#pragma mark - Methods

- (void)rampVolumeToZero:(BOOL)async {
    [BassUtil rampVolumeToZero:_channel async:async];
}

- (void)rampVolumeToNormal:(BOOL)async {
    [BassUtil rampVolumeToNormal:_channel async:async];
}

- (BOOL)lockSampleRate {
    return _lockSampleRate;
}

- (void)setLockSampleRate:(BOOL)lockSampleRate {
    _lockSampleRate = lockSampleRate;
    if (_lockSampleRate) {
        [self changeSystemSampleRateToChannelRate];
    }
}

- (BOOL)play:(AudioTrack *)track {

    [self stop];

    const char *filename = [track.url.path UTF8String];

    _channel = BASS_StreamCreateFile(FALSE, filename, 0, 0, BASS_ASYNCFILE) ;

    if (_channel) {
        [BassUtil setChannelDelegate:self channel:_channel];
        if (_lockSampleRate) {
            [self changeSystemSampleRateToChannelRate];
        }

        BASS_SetVolume(1.0);
        BOOL success = BASS_ChannelPlay(_channel, FALSE);

        if (success) {
            _currentTrack = track;
            track.duration = self.duration;
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [self->_delegate audioPlayer:self didStartPlaying:track];
            });
            return YES;
        }

    }

    [self stop];

    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [self->_delegate audioPlayer:self error:[BassUtil errorForLastError]];
    });

    return NO;
}

- (void)channelDidEnd {
    [self stop];
    [self->_delegate audioPlayer:self didFinishPlaying:_currentTrack];
}

- (void)playPause {
    if ([self isPlaying]) {
        [self pause];
    }
    else {
        [self resume];
    }
}

- (void)pause {
    [self rampVolumeToZero:NO];
    BASS_ChannelPause(_channel);
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [self->_delegate audioPlayer:self didPausePlaying:self->_currentTrack];
    });
}

- (void)resume {
    BASS_ChannelPlay(_channel, NO);
    [self rampVolumeToNormal:YES];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [self->_delegate audioPlayer:self didResumePlaying:self->_currentTrack];
    });
}

- (void)stop {
    if (_channel) {
        BASS_ChannelStop(_channel);
        BASS_StreamFree(_channel);
        _channel = 0;
    }
    _currentTrack = nil;
}

#pragma mark - Properties

- (BOOL)isPlaying {
    return _channel != 0 && BASS_ChannelIsActive(_channel);
}

- (BOOL)isPaused {
    return _channel != 0 && !self.isPlaying;
}

- (BOOL)isStopped {
    return _channel == 0;
}

- (NSTimeInterval)duration {
    if (_channel) {
        QWORD len = BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
        NSTimeInterval time = BASS_ChannelBytes2Seconds(_channel, len);
        return time;
    }
    return 0;
}

- (NSUInteger)numChannels {
    if (_channel) {
        BASS_CHANNELINFO info;
        BASS_ChannelGetInfo(_channel, &info);
        return info.chans;
    }
    return 0;
}

- (NSTimeInterval)position  {
    return [BassUtil getChannelPosition:_channel];
}

- (void)setPosition:(NSTimeInterval)pos {
    return [BassUtil setChannelPosition:_channel position:pos];
}

- (AudioTrack*)currentTrack {
    return _currentTrack;
}

#pragma mark - Sample rates

- (void)changeSystemSampleRateToChannelRate {
    if (!_channel) {
        return;
    }
    BASS_INFO bassInfo;
    BASS_CHANNELINFO channelInfo;
    BASS_GetInfo(&bassInfo);
    BASS_ChannelGetInfo(_channel, &channelInfo);
    if (bassInfo.freq != channelInfo.freq) {
        LogDebug(@"sample rate");
        LogDebug(@"  bass: %d", bassInfo.freq);
        LogDebug(@"  chan: %d", channelInfo.freq);
        [CoreAudioUtil setSampleRate:channelInfo.freq forDeviceUID:BassUtil.driverForCurrentDevice];
    }
}

#pragma mark - Output devices

- (void)systemAudioOutputDeviceDidChange {
    if (_selectedAudioDevice == -1) {
        [self setDefaultOutputDevice];
    }
}

- (NSInteger)currentOutputDeviceIndex {
    return _selectedAudioDevice;
}

- (BOOL)setOutputDevice:(NSInteger)newIndex {

    _selectedAudioDevice = newIndex;

    if (_selectedAudioDevice == -1) {
        return [self setDefaultOutputDevice];
    }

    // Skip nosound device
    DWORD newDeviceIndex = (DWORD)(newIndex + 1);
    BASS_DEVICEINFO info;
    int currentDevice = BASS_GetDevice();
    if (newDeviceIndex != currentDevice) {
        BOOL isPlaying = self.isPlaying;
        BASS_GetDeviceInfo((DWORD) newIndex, &info);
        BASS_Init(newDeviceIndex, PLAYBACK_RATE, 0, 0, 0);
        BASS_SetDevice(newDeviceIndex);
        if (_channel) {
            BASS_ChannelPause(_channel);
            BASS_ChannelSetDevice(_channel, newDeviceIndex);
            if (isPlaying) {
                BASS_ChannelPlay(_channel, NO);
            }
        }
    }
    return YES;
}

- (BOOL)setDefaultOutputDevice {
    BASS_DEVICEINFO info;
    for (NSUInteger d = 1; BASS_GetDeviceInfo((DWORD)d, &info); d++) {
        if (info.flags & BASS_DEVICE_DEFAULT) {
            if ([self setOutputDevice:d - 1]) {
                _selectedAudioDevice = -1;
                return YES;
            }
        }
    }
    return NO;
}

@end
