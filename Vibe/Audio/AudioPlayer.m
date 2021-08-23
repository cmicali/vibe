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
#import "AudioDeviceManager.h"
#import "WorkQueueThread.h"
#import "NSThread+Blocks.h"

@interface AudioPlayer () <BASSChannelDelegate>

@property (atomic) HSTREAM      channel;
@property (atomic) BOOL         lockSampleRate;

- (void)initWithDeviceIndexInternal:(int)newDeviceIndex;

@end

@implementation AudioPlayer {
    BOOL                    _lockSampleRate;
    WorkQueueThread*        _thread;
}


#pragma mark - Init

- (id)initWithDevice:(NSString *)deviceName lockSampleRate:(BOOL)shouldLockSampleRate delegate:(id <AudioPlayerDelegate>)delegate {
    self = [super init];
    if (self) {
        self.channel = 0;
        self.lockSampleRate = shouldLockSampleRate;
        _thread = [[WorkQueueThread alloc] init];
        [_thread start];
        self.delegate = delegate;
        [_thread run:^{

            LogDebug(@"AudioPlayer init");

            BASS_PluginLoad("libbassflac.dylib", 0);
            BASS_SetConfig(BASS_CONFIG_FLOATDSP, 1);

            AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForName:deviceName];
            self.currentlyRequestedAudioDeviceId = device.deviceId;

            [self initWithDeviceIndexInternal:(int) device.deviceId];

            [CoreAudioUtil listenForSystemOutputDeviceChanges:self];

            run_on_main_thread({
                [self.delegate audioPlayerDidInitialize:self];
            });

        }];
    }
    return self;
}

- (void)initWithDeviceIndexInternal:(int)newDeviceIndex {
    BOOL wasPlaying = self.isPlaying;
    if (wasPlaying) {
        BASS_ChannelPause(self.channel);
    }
    BASS_Free();
    if (!BASS_Init(newDeviceIndex, 44100, 0, NULL, NULL)) {
        int errorCode = BASS_ErrorGetCode();
        LogError(@"Error initializing BASS: %@", [BassUtil stringForErrorCode:errorCode]);
    }
    if (newDeviceIndex != -1) {
        BASS_SetDevice((DWORD) newDeviceIndex);
        if (self.channel) {
            BASS_ChannelSetDevice(self.channel, (DWORD) newDeviceIndex);
        }
        if (wasPlaying) {
            BASS_ChannelPlay(self.channel, NO);
        }
    }
    if (self.channel) {
        [self changeSystemSampleRateToChannelRate];
    }
}

- (void)dealloc  {
    BASS_Free();
    DDLogDebug(@"Bass freed");
}

#pragma mark - Methods

- (void)rampVolumeToZero:(BOOL)async {
    [_thread run:^{
        [BassUtil rampVolumeToZero:self.channel async:async];
    }];
}

- (void)rampVolumeToNormal:(BOOL)async {
    [_thread run:^{
        [BassUtil rampVolumeToNormal:self.channel async:async];
    }];
}

- (BOOL)lockSampleRate {
    return _lockSampleRate;
}

- (void)setLockSampleRate:(BOOL)lockSampleRate {
    _lockSampleRate = lockSampleRate;
    if (_lockSampleRate && _channel) {
        [_thread run:^{
            [self changeSystemSampleRateToChannelRate];
        }];
    }
}

- (void)play:(AudioTrack *)track {

    [_thread run:^{

        if (self.channel) {
            [BassUtil rampVolumeToZero:self.channel async:NO];
            BASS_StreamFree(self.channel);
            self.channel = 0;
        }

        self.currentTrack = nil;

        LogDebug(@"play file: %@", track.url.path);

        self.channel = BASS_StreamCreateFile(FALSE,  [track.url.path UTF8String], 0, 0, BASS_ASYNCFILE) ;

        if (self.channel) {
            [BassUtil setChannelDelegate:self channel:self.channel];
            [self changeSystemSampleRateToChannelRate];
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
    }];

}

- (void)playPause {
    [_thread run:^{
        if (self.isPlaying) {
            [BassUtil rampVolumeToZero:self.channel async:NO];
            if (BASS_ChannelPause(self.channel)) {
                run_on_main_thread({
                    [self.delegate audioPlayer:self didPausePlaying:self.currentTrack];
                });
                return;
            }
        }
        else {
            if (BASS_ChannelPlay(self.channel, NO)) {
                [BassUtil rampVolumeToNormal:self.channel async:YES];
                run_on_main_thread({
                    [self.delegate audioPlayer:self didPausePlaying:self.currentTrack];
                });
                return;
            }
        }
        [self sendDelegateLastError];
    }];
}

#pragma mark - Properties

- (BOOL)isPlaying {
    return self.channel != 0 && BASS_ChannelIsActive(self.channel) == BASS_ACTIVE_PLAYING;
}

- (BOOL)isPaused {
    return self.channel != 0 && (
            BASS_ChannelIsActive(self.channel) == BASS_ACTIVE_PAUSED ||
            BASS_ChannelIsActive(self.channel) == BASS_ACTIVE_PAUSED_DEVICE
    );
}

- (BOOL)isStopped {
    return self.channel == 0 || BASS_ChannelIsActive(self.channel) == BASS_ACTIVE_STOPPED;
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
    [_thread run:^{
        [BassUtil setChannelPosition:self.channel position:pos];
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:self.currentTrack];
        });
    }];
}

#pragma mark - BASSChannelDelegate

- (void)channelDidEnd {
    run_on_main_thread({
        [self.delegate audioPlayer:self didFinishPlaying:self.currentTrack];
    });
}

#pragma mark - Sample rates

- (void)changeSystemSampleRateToChannelRate {
    if (!self.channel || !_lockSampleRate) {
        return;
    }
    BASS_INFO bassInfo;
    BASS_CHANNELINFO channelInfo;
    BASS_GetInfo(&bassInfo);
    BASS_ChannelGetInfo(self.channel, &channelInfo);
    if (bassInfo.freq != channelInfo.freq) {
        LogDebug(@"AudioPlayer: Changing system sample rate");
        LogDebug(@"  from: %d", bassInfo.freq);
        LogDebug(@"    to: %d", channelInfo.freq);
        [CoreAudioUtil setBestSampleRate:channelInfo.freq forDeviceUID:BassUtil.driverForCurrentDevice];
    }
}

#pragma mark - Output devices

- (void)systemAudioOutputDeviceDidChange {
    if (self.currentlyRequestedAudioDeviceId == -1) {
        [self setOutputDevice:self.currentlyRequestedAudioDeviceId];
    }
}

- (NSInteger)currentlyActiveAudioDeviceId {
    return BASS_GetDevice();
}

- (void)setOutputDevice:(NSInteger)outputDeviceIndex {

    [_thread run:^{

        LogDebug(@"setOutputDevice: %@", @(outputDeviceIndex));
        BASS_DEVICEINFO info;

        DWORD newDeviceIndex = 0;

        if (outputDeviceIndex >= 0) {
            newDeviceIndex = (DWORD) outputDeviceIndex;
        }
        else if (outputDeviceIndex == -1) {
            // Find default output device
            for (NSUInteger d = 1; BASS_GetDeviceInfo((DWORD)d, &info); d++) {
                if (info.flags & BASS_DEVICE_DEFAULT) {
                    newDeviceIndex = (DWORD)d;
                    break;
                }
            }
        }

        if (newDeviceIndex == 0) {
            LogError(@"Unable to find system default output device, and no sound (0) is disallowed");
            [self sendDelegateLastError];
            return;
        }

        int currentDevice = BASS_GetDevice();

        LogDebug(@"current: %@ new: %@", @(currentDevice), @(newDeviceIndex));

        if (newDeviceIndex != currentDevice) {
            [self initWithDeviceIndexInternal:newDeviceIndex];
        }

        self.currentlyRequestedAudioDeviceId = outputDeviceIndex;

        LogDebug(@"currentlyRequestedAudioDeviceId: %@", @(self.currentlyRequestedAudioDeviceId));

        run_on_main_thread({
            [self.delegate audioPlayer:self didChangeOuputDevice:self.currentlyRequestedAudioDeviceId];
        });

    }];

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
