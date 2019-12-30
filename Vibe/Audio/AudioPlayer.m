//
//  BASSAudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <CoreAudio/CoreAudio.h>
#import "AudioPlayer.h"
#import "BassWrapper.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveform.h"
#import "Util.h"
#import "AudioDevice.h"

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

#define PLAYBACK_RATE   44100

@interface AudioPlayer () {
    HSTREAM _channel;
}

@end

@implementation AudioPlayer {
    NSCache *_metadataCache;
    AudioTrack *_currentTrack;
    NSInteger _selectedAudioDevice;
}

- (id)initWithDevice:(NSInteger)deviceIndex {
    self = [super init];
    if (self) {
        _selectedAudioDevice = deviceIndex;
        [self setup];
    }
    return self;
}

OSStatus outputDeviceChangedCallback(AudioObjectID inObjectID,
                                     UInt32 inNumberAddresses,
                                     const AudioObjectPropertyAddress *inAddresses,
                                     void *inClientData) {
    __block AudioPlayer *player = (__bridge AudioPlayer *)(inClientData);
    dispatch_async(dispatch_get_main_queue(), ^{
        [player systemOutputDeviceDidChange];
    });
    return kAudioHardwareNoError;
}

- (void)setup {

    _channel = 0;

    _metadataCache = [[NSCache alloc] init];

    BASS_PluginLoad("libbassflac.dylib", 0);

    BASS_SetConfig(BASS_CONFIG_FLOATDSP, 1);

    if (!BASS_Init(_selectedAudioDevice, PLAYBACK_RATE, 0, NULL, NULL)) {
        DDLogError(@"Error initializing BASS");
    }
    BASS_INFO info;
    BASS_GetInfo(&info);

    LogDebug(@"BASS init");
    LogDebug(@"  freq: %d latency: %d minrate: %d maxrate: %d flags: %d", info.freq, info.latency, info.minrate, info.maxrate, info.flags);

    CFRunLoopRef nullRunLoop =  NULL;
    AudioObjectPropertyAddress runLoopProperty = {
            kAudioHardwarePropertyRunLoop,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
    };
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &runLoopProperty, 0, NULL, sizeof(CFRunLoopRef), &nullRunLoop);
    AudioObjectPropertyAddress outputDeviceAddress = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
    };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &outputDeviceAddress, &outputDeviceChangedCallback, (__bridge void *)self);

}

- (AudioTrack*)currentTrack {
    return _currentTrack;
}

- (void)rampVolumeToZero:(BOOL)async {
    if (_channel) {
        BASS_ChannelSlideAttribute(_channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 0, 200);
        if (!async) {
            runWithTimeout(1, ^{
               while(BASS_ChannelIsSliding(_channel, BASS_ATTRIB_VOL)) {
                   usleep(10000);
               };
            });
        }
    }
}

- (void)rampVolumeToNormal:(BOOL)async {
    if (_channel) {
        BASS_ChannelSlideAttribute(_channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 1, 100);
        if (!async) {
            __block AudioPlayer *weakSelf  = self;
            runWithTimeout(1, ^{
                while(BASS_ChannelIsSliding(weakSelf->_channel, BASS_ATTRIB_VOL));
            });
        }
    }
}

- (void)dealloc  {
    [self stop];
    BASS_Free();
    DDLogDebug(@"Bass freed");
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

void CALLBACK DownloadFinishedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
//    __block AudioPlayer *player = (__bridge AudioPlayer *)(user);
    LogDebug(@"Download finished");
    dispatch_async(dispatch_get_main_queue(), ^(void) {
    });
}

void CALLBACK DeviceFailedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
//    __block AudioPlayer *player = (__bridge AudioPlayer *)(user);
    LogError(@"Device failed");
    dispatch_async(dispatch_get_main_queue(), ^(void) {
    });
}

void CALLBACK DeviceChangedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
//    __block AudioPlayer *player = (__bridge AudioPlayer *)(user);
    LogError(@"Device changed");
    dispatch_async(dispatch_get_main_queue(), ^(void) {
    });
}

- (BOOL)play:(AudioTrack *)track {

    [self stop];

    const char *filename = [track.url.path UTF8String];

    _channel = BASS_StreamCreateFile(FALSE, filename, 0, 0, BASS_ASYNCFILE) ;

    WEAK_SELF

    if (_channel) {

        if (!BASS_ChannelSetSync(_channel, BASS_SYNC_END, 0, ChannelEndedCallback, (__bridge void *)self)) {
            int code = BASS_ErrorGetCode();
            NSError *err = [self errorForErrorCode:code];
            LogError(@"Bass error: %@", err.userInfo[NSLocalizedDescriptionKey]);
        }
        if (!BASS_ChannelSetSync(_channel, BASS_SYNC_DOWNLOAD, 0, DownloadFinishedCallback, (__bridge void *)self) ) {
            int code = BASS_ErrorGetCode();
            NSError *err = [self errorForErrorCode:code];
            LogError(@"Bass error: %@", err.userInfo[NSLocalizedDescriptionKey]);
        }
        if (!BASS_ChannelSetSync(_channel, BASS_SYNC_DEV_FAIL, 0, DeviceFailedCallback, (__bridge void *)self) ) {
            int code = BASS_ErrorGetCode();
            NSError *err = [self errorForErrorCode:code];
            LogError(@"Bass error: %@", err.userInfo[NSLocalizedDescriptionKey]);
        }
        if (!BASS_ChannelSetSync(_channel, BASS_SYNC_DEV_FORMAT, 0, DeviceChangedCallback, (__bridge void *)self) ) {
            int code = BASS_ErrorGetCode();
            NSError *err = [self errorForErrorCode:code];
            LogError(@"Bass error: %@", err.userInfo[NSLocalizedDescriptionKey]);
        }

        BOOL success = BASS_ChannelPlay(_channel, FALSE);

        if (success) {
            _currentTrack = track;
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [weakSelf->_delegate audioPlayer:self didStartPlaying:track];
            });
            return YES;
        }

    }
    [self stop];
    int code = BASS_ErrorGetCode();
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        NSError *err = [weakSelf errorForErrorCode:code];
        LogError(@"Bass error: %@", err.userInfo[NSLocalizedDescriptionKey]);
        [weakSelf->_delegate audioPlayer:self error:err];
    });

    return NO;
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
    BASS_ChannelPause(_channel);
    __block AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [weakSelf->_delegate audioPlayer:weakSelf didPausePlaying:weakSelf->_currentTrack];
    });
}

- (void)resume {
    BASS_ChannelPlay(_channel, NO);
    __block AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [weakSelf->_delegate audioPlayer:weakSelf didResumePlaying:weakSelf->_currentTrack];
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

- (BOOL)isPlaying {
    DWORD isPlaying = BASS_ChannelIsActive(_channel);
    return isPlaying == BASS_ACTIVE_PLAYING;
}

- (BOOL)isPaused {
    return _channel != 0 && !self.isPlaying;
}

- (BOOL)isStopped {
    return _channel == 0;
}

- (NSTimeInterval)duration {
    QWORD len = BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
    double time = BASS_ChannelBytes2Seconds(_channel, len);
    return time;
}

- (NSUInteger)numChannels {
    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(_channel, &info);
    return info.chans;
}

- (QWORD)numBytes {
    if (_channel) {
        return BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
    }
    else {
        return 0;
    }
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

- (uint32_t)readAudioSamples:(void *)buffer length:(uint32_t)length {
    return BASS_ChannelGetData(_channel, buffer, length);
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    __block AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
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
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [weakSelf->_delegate audioPlayer:self didFinishLoadingMetadata:tracks.count];
        });
    });
}

- (NSError *)errorForErrorCode:(AudioPlayerError)erro {
    NSString *str = @"Unknown error";

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

- (NSInteger)numOutputDevices {
    int a, count = 0;
    BASS_DEVICEINFO info;
    for (a = 1; BASS_GetDeviceInfo(a, &info); a++)
        if (info.flags & BASS_DEVICE_ENABLED)
            count++; // count it
    return count;
}

- (AudioDevice *)outputDeviceForIndex:(NSUInteger)index {
    AudioDevice *dev = [[AudioDevice alloc] init];
    if (index == -1) {
        dev.name = @"System Default";
        dev.index = index;
        return dev;
    }
    else {
        BASS_DEVICEINFO info;
        if (!BASS_GetDeviceInfo((DWORD)(index + 1), &info)) {
            return nil;
        }
        dev.name = [NSString stringWithCString:info.name encoding:NSUTF8StringEncoding];
        dev.index = index;
    }
    return dev;
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

- (void)systemOutputDeviceDidChange {
    if (_selectedAudioDevice == -1) {
        [self setDefaultOutputDevice];
    }
}


@end
