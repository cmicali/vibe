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

+ (void)waitForChannelSlide:(HCHANNEL)channel attribute:(DWORD)attribute  {
    runWithTimeout(2, ^{
        while(BASS_ChannelIsSliding(channel, attribute));
    });
}
+ (void)rampVolumeToZero:(HCHANNEL)channel async:(BOOL)async {
    if (channel) {
        BASS_ChannelSlideAttribute(channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 0, 1000);
        if (!async) {
            [self waitForChannelSlide:channel attribute:BASS_ATTRIB_VOL];
        }
    }
}

+ (void)rampVolumeToNormal:(HCHANNEL)channel async:(BOOL)async{
    if (channel) {
        BASS_ChannelSlideAttribute(channel, BASS_ATTRIB_VOL | BASS_SLIDE_LOG, 1, 100);
        if (!async) {
            [self waitForChannelSlide:channel attribute:BASS_ATTRIB_VOL];
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

static NSDictionary* dic = nil;

+ (NSDictionary*)errorCodeToStringDict {
    static NSDictionary *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = @{
                @(BASS_OK):             @"OK",
                @(BASS_ERROR_MEM):      @"BASS_ERROR_MEM: There is insufficient memory.",
                @(BASS_ERROR_FILEOPEN): @"BASS_ERROR_FILEOPEN: The file could not be opened.",
                @(BASS_ERROR_DRIVER):   @"BASS_ERROR_DRIVER: Can't find a free or valid driver",
                @(BASS_ERROR_BUFLOST):  @"BASS_ERROR_BUFLOST: Sample buffer was lost",
                @(BASS_ERROR_HANDLE):   @"BASS_ERROR_HANDLE: Invalid handle",
                @(BASS_ERROR_FORMAT):   @"BASS_ERROR_FORMAT: Unsupported sample format",
                @(BASS_ERROR_POSITION): @"BASS_ERROR_POSITION: Invalid position",
                @(BASS_ERROR_INIT):     @"BASS_ERROR_INIT: BASS_Init has not been successfully called.",
                @(BASS_ERROR_START):    @"BASS_ERROR_START: BASS_Start has not been successfully called.",
                @(BASS_ERROR_SSL):      @"BASS_ERROR_SSL: SSL/HTTPS support is not available.",
                @(BASS_ERROR_ALREADY):  @"BASS_ERROR_ALREADY: Already initialized, paused, etc",
                @(BASS_ERROR_NOTAUDIO): @"BASS_ERROR_NOTAUDIO: File does not contain audio",
                @(BASS_ERROR_NOCHAN):   @"BASS_ERROR_NOCHAN: Cannot get a free channel",
                @(BASS_ERROR_ILLTYPE):  @"BASS_ERROR_ILLTYPE: An illegal type was specified",
                @(BASS_ERROR_ILLPARAM): @"BASS_ERROR_ILLPARAM: url is not a valid URL.",
                @(BASS_ERROR_NO3D):     @"BASS_ERROR_NO3D: Could not initialize 3D support.",
                @(BASS_ERROR_NOEAX):    @"BASS_ERROR_NOEAX: No EAX support",
                @(BASS_ERROR_DEVICE):   @"BASS_ERROR_DEVICE: Illegal device number",
                @(BASS_ERROR_NOPLAY):   @"BASS_ERROR_NOPLAY: Not playing",
                @(BASS_ERROR_FREQ):     @"BASS_ERROR_FREQ: Illegal sample rate",
                @(BASS_ERROR_NOTFILE):  @"BASS_ERROR_NOTFILE: The stream is not a file stream",
                @(BASS_ERROR_NOHW):     @"BASS_ERROR_NOHW: No hardware voices available",
                @(BASS_ERROR_EMPTY):    @"BASS_ERROR_EMPTY: The MOD music has no sequence data",
                @(BASS_ERROR_NONET):    @"BASS_ERROR_NONET: No internet connection could be opened. Can be caused by a bad proxy setting.",
                @(BASS_ERROR_CREATE):   @"BASS_ERROR_CREATE: Could not create file",
                @(BASS_ERROR_NOFX):     @"BASS_ERROR_NOFX: Effects are not available",
                @(BASS_ERROR_NOTAVAIL): @"BASS_ERROR_NOTAVAIL: Only decoding channels (BASS_STREAM_DECODE) are allowed when using the \"no sound\" device. The BASS_STREAM_AUTOFREE flag is also unavailable to decoding channels.",
                @(BASS_ERROR_DECODE):   @"BASS_ERROR_DECODE: The channel is not a decoding channel",
                @(BASS_ERROR_DX):       @"BASS_ERROR_DX: Required DirectX not installed",
                @(BASS_ERROR_TIMEOUT):  @"BASS_ERROR_TIMEOUT: The server did not respond to the request within the timeout period, as set with the BASS_CONFIG_NET_TIMEOUT config option.",
                @(BASS_ERROR_FILEFORM): @"BASS_ERROR_FILEFORM: The file's format is not recognised/supported.",
                @(BASS_ERROR_SPEAKER):  @"BASS_ERROR_SPEAKER: The sample format is not supported by the device/drivers. If the stream is more than stereo or the BASS_SAMPLE_FLOAT flag is used, it could be that they are not supported.",
                @(BASS_ERROR_VERSION):  @"BASS_ERROR_VERSION: Invalid BASS version (add-on issue?)",
                @(BASS_ERROR_CODEC):    @"BASS_ERROR_CODEC: The file uses a codec that is not available/supported. This can apply to WAV and AIFF files, and also MP3 files when using the \"MP3-free\" BASS version.",
                @(BASS_ERROR_ENDED):    @"BASS_ERROR_ENDED: The channel/file has ended",
                @(BASS_ERROR_BUSY):     @"BASS_ERROR_BUSY: The device is busy",
                @(BASS_ERROR_UNSTREAMABLE): @"BASS_ERROR_UNSTREAMABLE: The file is unstreamable",
                @(BASS_ERROR_UNKNOWN):  @"BASS_ERROR_UNKNOWN: Unknown error"
        };
    });
    return instance;
}

+ (NSString *)stringForLastError {
    return [self stringForErrorCode:BASS_ErrorGetCode()];
}

+ (NSString *)stringForErrorCode:(int)erro {
    NSString *str = self.errorCodeToStringDict[@(erro)];
    if (!str) {
        str = [NSString stringWithFormat:@"Unknown error code: %d", erro];
    }
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
