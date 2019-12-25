//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"
#import "AudioPlayer.h"


@implementation AudioWaveform {

    float *_samples;
    QWORD _numBytes;
    DWORD _numChannels;

    NSUInteger _size;
    NSArray *_minValues;
    NSArray *_maxValues;

    HSTREAM _channel;

}

void CALLBACK CChannelEndedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    LogDebug(@"Channel ended");
}

void CALLBACK CDownloadFinishedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    LogDebug(@"Download finished");
}

- (id)initWithFilename:(NSString *)filename {
    self = [super init];
    if (self) {
        __block AudioWaveform *weakSelf = self;
        _size = 512;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [weakSelf load:filename];
        });
    }
    return self;
}

- (void)load:(NSString *)filename {
    TIME_START
    LogDebug(@"Loading %@", filename);
    _channel = BASS_StreamCreateFile(FALSE, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE);
    if (!_channel) {
        LogDebug(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
    }
    if (!BASS_ChannelSetSync(_channel, BASS_SYNC_END, 0, CChannelEndedCallback, (__bridge void *) self)) {
        LogDebug(@"BASS_ChannelSetSync error: %d", BASS_ErrorGetCode());
    }
    if (!BASS_ChannelSetSync(_channel, BASS_SYNC_DOWNLOAD, 0, CDownloadFinishedCallback, (__bridge void *) self)) {
        LogDebug(@"BASS_ChannelSetSync error: %d", BASS_ErrorGetCode());
    }
    _numBytes = BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
    _samples = malloc(_numBytes);
    DWORD bytesRead = BASS_ChannelGetData(_channel, _samples, _numBytes);
    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(_channel, &info);
    _numChannels = info.chans;
    LogDebug(@"bytesRead: %d bytesTotal: %d", bytesRead, _numBytes);
    [self precalculate];
    TIME_END
}

- (void)dealloc {
    free(_samples);
}

- (MinMax)getMinMax:(NSUInteger)index {
    MinMax r;
    memset(&r, 0, sizeof(MinMax));
    if (index < _size) {
        r.min = [((NSNumber*)_minValues[index]) floatValue];
        r.max = [((NSNumber*)_maxValues[index]) floatValue];
    }
    return r;
}

- (MinMax)findMinMax:(float *)buffer length:(NSUInteger)length {
    MinMax result;
    result.max = -MAXFLOAT;
    result.min = MAXFLOAT;
    NSUInteger i = 0;
    while (i < (length * _numChannels)) {
        float value = 0;
        for (int j = 0; j < _numChannels; j++) {
            value = value + buffer[i];
            i++;
        }
        value /= _numChannels;
        if (value < result.min) result.min = value;
        if (value > result.max) result.max = value;
    }
    return result;
}

- (void)precalculate {
    NSMutableArray *minResult = [[NSMutableArray alloc] initWithCapacity:_size];
    NSMutableArray *maxResult = [[NSMutableArray alloc] initWithCapacity:_size];
    NSUInteger chunkSize = _numBytes / sizeof(float) / _size / _numChannels;
    float *buf = _samples;
    for (int i = 0; i < _size; i++) {
        MinMax result = [self findMinMax:buf length:chunkSize];
        [minResult addObject:@(result.min)];
        [maxResult addObject:@(result.max)];
        buf += chunkSize;
    }
    _minValues = minResult;
    _maxValues = maxResult;
}

@end