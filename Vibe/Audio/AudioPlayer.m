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
#import "BassUtil.h"
#import "MainPlayerController.h"

#define PLAYBACK_RATE   44100

@interface AudioPlayer () <BASSChannelDelegate>

@property (atomic) HSTREAM      channel;
@property (atomic) NSInteger    selectedAudioDevice;
@property (atomic) BOOL         lockSampleRate;

@end

@implementation AudioPlayer {
    dispatch_queue_t        _playerQueue;
    BOOL                    _lockSampleRate;
}


#pragma mark - Init

- (id)initWithDevice:(NSInteger)deviceIndex lockSampleRate:(BOOL)shouldLockSampleRate delegate:(MainPlayerController *)delegate {
    self = [super init];
    if (self) {
        self.channel = 0;
        self.selectedAudioDevice = deviceIndex;
        self.lockSampleRate = shouldLockSampleRate;
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _playerQueue = dispatch_queue_create("AudioPlayer", queueAttributes);
        self.delegate = delegate;
        dispatch_async(_playerQueue, ^{
            [self setup];
        });
    }
    return self;
}

- (void)setup {
    BASS_PluginLoad("libbassflac.dylib", 0);
    BASS_SetConfig(BASS_CONFIG_FLOATDSP, 1);
    if (!BASS_Init((int)self.selectedAudioDevice, PLAYBACK_RATE, 0, NULL, NULL)) {
        DDLogError(@"Error initializing BASS");
    }
    BASS_INFO info;
    BASS_GetInfo(&info);
    LogDebug(@"BASS init");
    LogDebug(@"  freq: %d latency: %d minrate: %d maxrate: %d flags: %d", info.freq, info.latency, info.minrate, info.maxrate, info.flags);
    [CoreAudioUtil listenForSystemOutputDeviceChanges:self];
    run_on_main_thread({
        [self.delegate audioPlayerDidInitialize:self];
    });
}

- (void)dealloc  {
    BASS_Free();
    DDLogDebug(@"Bass freed");
}

#pragma mark - Methods
//
//- (void)rampVolumeToZero:(BOOL)async {
//    dispatch_async(_playerQueue, ^{
//        [BassUtil rampVolumeToZero:self.channel async:async];
//    });
//}
//
//- (void)rampVolumeToNormal:(BOOL)async {
//    dispatch_async(_playerQueue, ^{
//        [BassUtil rampVolumeToNormal:self.channel async:async];
//    });
//}

- (BOOL)lockSampleRate {
    return _lockSampleRate;
}

- (void)setLockSampleRate:(BOOL)lockSampleRate {
    _lockSampleRate = lockSampleRate;
    if (_lockSampleRate) {
        dispatch_async(_playerQueue, ^{
            [self changeSystemSampleRateToChannelRate];
        });
    }
}

- (void)play:(AudioTrack *)track {

    const char *filename = [track.url.path UTF8String];

    dispatch_async(_playerQueue, ^{

        if (self.channel) {
            BASS_ChannelStop(self.channel);
            BASS_StreamFree(self.channel);
        }

        self.currentTrack = nil;

        self.channel = BASS_StreamCreateFile(FALSE, filename, 0, 0, BASS_ASYNCFILE) ;

        if (self.channel) {
            [BassUtil setChannelDelegate:self channel:self.channel];
            if (self.lockSampleRate) {
                [self changeSystemSampleRateToChannelRate];
            }
            BOOL success = BASS_ChannelPlay(self.channel, FALSE);
            if (success) {
                self.currentTrack = track;
                track.duration = self.duration;
                run_on_main_thread({
                    [self.delegate audioPlayer:self didStartPlaying:track];
                });
                return;
            }
            BASS_StreamFree(self.channel);
            self.channel = 0;
        }
        [self sendDelegateLastError];
    });

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
    dispatch_async(_playerQueue, ^{
        if (BASS_ChannelPause(self.channel)) {
            run_on_main_thread({
                [self.delegate audioPlayer:self didPausePlaying:self.currentTrack];
            });
        }
        else {
            [self sendDelegateLastError];
        }
    });
}

- (void)resume {
    dispatch_async(_playerQueue, ^{
        if (BASS_ChannelPlay(self.channel, NO)) {
            run_on_main_thread({
                [self.delegate audioPlayer:self didResumePlaying:self.currentTrack];
            });
        }
        else {
            [self sendDelegateLastError];
        }
    });
}

#pragma mark - Properties

- (BOOL)isPlaying {
    return self.channel != 0 && BASS_ChannelIsActive(self.channel);
}

- (BOOL)isPaused {
    return self.channel != 0 && !self.isPlaying;
}

- (BOOL)isStopped {
    return self.channel == 0;
}

- (NSTimeInterval)duration {
    if (self.channel) {
        QWORD len = BASS_ChannelGetLength(self.channel, BASS_POS_BYTE);
        NSTimeInterval time = BASS_ChannelBytes2Seconds(self.channel, len);
        return time;
    }
    return 0;
}

- (NSUInteger)numChannels {
    if (self.channel) {
        BASS_CHANNELINFO info;
        BASS_ChannelGetInfo(self.channel, &info);
        return info.chans;
    }
    return 0;
}

- (NSTimeInterval)position  {
    return [BassUtil getChannelPosition:self.channel];
}

- (void)setPosition:(NSTimeInterval)pos {
    dispatch_async(_playerQueue, ^{
        [BassUtil setChannelPosition:self.channel position:pos];
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:self.currentTrack];
        });
    });
}

#pragma mark - BASSChannelDelegate

- (void)channelDidEnd {
    run_on_main_thread({
        [self.delegate audioPlayer:self didFinishPlaying:self.currentTrack];
    });
}

#pragma mark - Sample rates

- (void)changeSystemSampleRateToChannelRate {
    if (!self.channel) {
        return;
    }
    BASS_INFO bassInfo;
    BASS_CHANNELINFO channelInfo;
    BASS_GetInfo(&bassInfo);
    BASS_ChannelGetInfo(self.channel, &channelInfo);
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

- (void)setOutputDevice:(NSInteger)outputDeviceIndex {

    dispatch_async(_playerQueue, ^{

        BASS_DEVICEINFO info;

        self.selectedAudioDevice = outputDeviceIndex;

        DWORD newDeviceIndex = 0;

        if (outputDeviceIndex == -1) {
            // Find default output device
            for (NSUInteger d = 1; BASS_GetDeviceInfo((DWORD)d, &info); d++) {
                if (info.flags & BASS_DEVICE_DEFAULT) {
                    newDeviceIndex = (DWORD)d;
                    break;
                }
            }
            if (newDeviceIndex == 0) {
                // We couldn't find the default device
                LogError(@"Unable to find system default output device");
                [self sendDelegateLastError];
                return;
            }
        }
        else {
            newDeviceIndex = (DWORD) (outputDeviceIndex + 1);
        }

        int currentDevice = BASS_GetDevice();

        if (newDeviceIndex != currentDevice) {
            BOOL isPlaying = self.isPlaying;
            BASS_GetDeviceInfo((DWORD) outputDeviceIndex, &info);
            BASS_Init(newDeviceIndex, PLAYBACK_RATE, 0, 0, 0);
            BASS_SetDevice(newDeviceIndex);
            if (self.channel) {
                BASS_ChannelPause(self.channel);
                BASS_ChannelSetDevice(self.channel, newDeviceIndex);
                if (isPlaying) {
                    BASS_ChannelPlay(self.channel, NO);
                }
            }
            run_on_main_thread({
                [self.delegate audioPlayer:self didChangeOuputDevice:newDeviceIndex];
            });
        }
    });

}

- (void)setDefaultOutputDevice {
    [self setSelectedAudioDevice:-1];
}

#pragma mark - Helpers

- (void)sendDelegateLastError {
    int errorCode = BASS_ErrorGetCode();
    LogError(@"AudioPlayer Error: %@", [BassUtil stringForErrorCode:errorCode]);
    NSError *error = [BassUtil errorForErrorCode:errorCode];
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

@end
