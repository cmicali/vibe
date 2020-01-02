//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BassUtil.h"
#import "BassWrapper.h"
#import "Util.h"

@implementation BassUtil

+ (BASS_DEVICEINFO) infoForCurrentDevice {
    return [self infoForDevice:BASS_GetDevice()];
}

+ (BASS_DEVICEINFO) infoForDevice:(DWORD)deviceId {
    BASS_DEVICEINFO info;
    BASS_GetDeviceInfo(deviceId, &info);
    return info;
}

+ (NSString *)driverForCurrentDevice {
    return [NSString stringWithUTF8String:self.infoForCurrentDevice.driver];
}

+ (void)rampVolumeToZero:(HCHANNEL)channel async:(BOOL)async {
    if (channel) {
        BASS_ChannelSlideAttribute(channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 0, 100);
        if (!async) {
            runWithTimeout(1, ^{
                while(BASS_ChannelIsSliding(channel, BASS_ATTRIB_VOL)) {
                    usleep(10000);
                };
            });
        }
    }
}

+ (void)rampVolumeToNormal:(HCHANNEL)channel async:(BOOL)async{
    if (channel) {
        BASS_ChannelSlideAttribute(channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 1, 100);
        if (!async) {
            runWithTimeout(1, ^{
                while(BASS_ChannelIsSliding(channel, BASS_ATTRIB_VOL));
            });
        }
    }
}

+ (NSTimeInterval)getChannelPosition:(HCHANNEL)channel  {
    if (channel) {
        QWORD len = BASS_ChannelGetPosition(channel, BASS_POS_BYTE);
        double position = BASS_ChannelBytes2Seconds(channel, len);
        return position;
    }
    return 0;
}

+ (void)setChannelPosition:(HCHANNEL)channel position:(NSTimeInterval)pos {
    if (channel) {
        QWORD seekTo = BASS_ChannelSeconds2Bytes(channel, pos);
        BASS_ChannelSetPosition(channel, seekTo, BASS_POS_BYTE);
    }
}

#pragma mark Callbacks

// the sync callback
void CALLBACK ChannelEndedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    id<BASSChannelDelegate> delegate = (__bridge id<BASSChannelDelegate>)(user);
    [delegate channelDidEnd];
}

void CALLBACK DownloadFinishedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    id<BASSChannelDelegate> delegate = (__bridge id<BASSChannelDelegate>)(user);
    [delegate channelDownloadDidFinish];
}

void CALLBACK DeviceFailedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    id<BASSChannelDelegate> delegate = (__bridge id<BASSChannelDelegate>)(user);
    [delegate channelDeviceDidFail];
}

void CALLBACK DeviceChangedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    __block id<BASSChannelDelegate> delegate = (__bridge id<BASSChannelDelegate>)(user);
    [delegate channelDeviceDidChange];
}

+ (BOOL)setChannelDelegate:(id <BASSChannelDelegate>)delegate channel:(HCHANNEL)channel {
    void *user = (__bridge void *)delegate;
    BOOL success = YES;
    if ([delegate respondsToSelector:@selector(channelDidEnd)]) {
        if (!BASS_ChannelSetSync(channel, BASS_SYNC_END, 0, ChannelEndedCallback, user)) {
            success = NO;
        }
    }
    if ([delegate respondsToSelector:@selector(channelDownloadDidFinish)]) {
        if (!BASS_ChannelSetSync(channel, BASS_SYNC_DOWNLOAD, 0, DownloadFinishedCallback, user)) {
            success = NO;
        }
    }
    if ([delegate respondsToSelector:@selector(channelDeviceDidFail)]) {
        if (!BASS_ChannelSetSync(channel, BASS_SYNC_DEV_FAIL, 0, DeviceFailedCallback, user)) {
            success = NO;
        }
    }
    if ([delegate respondsToSelector:@selector(channelDeviceDidChange)]) {
        if (!BASS_ChannelSetSync(channel, BASS_SYNC_DEV_FORMAT, 0, DeviceChangedCallback, user)) {
            success = NO;
        }
    }
    return success;
}

#pragma mark Error handling

+ (NSString *)stringForLastError {
    return [self stringForErrorCode:BASS_ErrorGetCode()];
}

+ (NSString *)stringForErrorCode:(int)erro {
    NSString *str = [NSString stringWithFormat:@"Unknown error: %d", erro];
    if(erro == BASS_ERROR_INIT)
        str = @"BASS_ERROR_INIT: BASS_Init has not been successfully called.";
    else if(erro == BASS_ERROR_NOTAVAIL)
        str = @"BASS_ERROR_NOTAVAIL: Only decoding channels (BASS_STREAM_DECODE) are allowed when using the \"no sound\" device. The BASS_STREAM_AUTOFREE flag is also unavailable to decoding channels.";
    else if(erro == BASS_ERROR_NONET)
        str = @"BASS_ERROR_NONET: No internet connection could be opened. Can be caused by a bad proxy setting.";
    else if(erro == BASS_ERROR_ILLPARAM)
        str = @"BASS_ERROR_ILLPARAM: url is not a valid URL.";
    else if(erro == BASS_ERROR_SSL)
        str = @"BASS_ERROR_SSL: SSL/HTTPS support is not available.";
    else if(erro == BASS_ERROR_TIMEOUT)
        str = @"BASS_ERROR_TIMEOUT: The server did not respond to the request within the timeout period, as set with the BASS_CONFIG_NET_TIMEOUT config option.";
    else if(erro == BASS_ERROR_FILEOPEN)
        str = @"BASS_ERROR_FILEOPEN: The file could not be opened.";
    else if(erro == BASS_ERROR_FILEFORM)
        str = @"BASS_ERROR_FILEFORM: The file's format is not recognised/supported.";
    else if(erro == BASS_ERROR_CODEC)
        str = @"BASS_ERROR_CODEC: The file uses a codec that is not available/supported. This can apply to WAV and AIFF files, and also MP3 files when using the \"MP3-free\" BASS version.";
    else if(erro == BASS_ERROR_SPEAKER)
        str = @"BASS_ERROR_SPEAKER: The sample format is not supported by the device/drivers. If the stream is more than stereo or the BASS_SAMPLE_FLOAT flag is used, it could be that they are not supported.";
    else if(erro == BASS_ERROR_MEM)
        str = @"BASS_ERROR_MEM: There is insufficient memory.";
    else if(erro == BASS_ERROR_NO3D)
        str = @"BASS_ERROR_NO3D: Could not initialize 3D support.";
    else if(erro == BASS_ERROR_UNKNOWN)
        str = @"BASS_ERROR_UNKNOWN: Some other mystery problem! Usually this is when the Internet is available but the server/port at the specific URL isn't.";
    return str;
}

+ (NSError *)errorForErrorCode:(int)erro {
    return [NSError errorWithDomain:@"com.commonwealthrecordings.Vibe"
                               code:erro
                           userInfo:@{NSLocalizedDescriptionKey: [self stringForErrorCode:erro]}];
}

+ (NSError *)errorForLastError {
    return [self errorForErrorCode:BASS_ErrorGetCode()];
}

@end
