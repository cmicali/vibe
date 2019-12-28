//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"
#import "AudioPlayer.h"

#import "BassWrapper.h"

#define SIZE    512
@implementation AudioWaveform {

    NSUInteger _numChunks;
    HSTREAM _channel;

    MinMax _waveform[SIZE];
    MinMax _defaultWaveform;

    dispatch_semaphore_t _loaderSemaphore;

}

- (id)init {
    self = [super init];
    if (self) {
        _numChunks = SIZE;
        _loaderSemaphore = dispatch_semaphore_create(0);
        self.isCancelled = NO;
        self.isFinished = NO;
        for (int i = 0; i < _numChunks; ++i) {
            _waveform[i].min = 0;
            _waveform[i].max = 0;
        }
        _defaultWaveform.min = 0;
        _defaultWaveform.max = 0;
    }
    return self;
}

- (BOOL)load:(NSString *)filename {
    LogDebug(@"Loading %@", filename);
    _channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE);
    if (!_channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
    }
    return _channel != 0;
}

- (void)scan {

    self.isCancelled = NO;
    self.isFinished = NO;

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(_channel, &info);
    NSUInteger numChannels = info.chans;

    NSUInteger totalBytes = BASS_ChannelGetLength(_channel, BASS_POS_BYTE);
    uint32_t chunkSize = uint32_t(totalBytes / sizeof(float) / _numChunks);
    if (chunkSize % 2) {
        chunkSize++;
    }

    float *buffer = (float*)malloc(chunkSize * sizeof(float) * 8);

    uint32_t bytesProcessed = 0;

    for (int i = 0; i < _numChunks && !self.isCancelled; i++) {

        BASS_ChannelSetPosition(_channel, bytesProcessed, BASS_POS_BYTE);

        int bytesRead = BASS_ChannelGetData(_channel, buffer, chunkSize + (16 * 1024));
        int len = min(chunkSize, bytesRead);
        _waveform[i] = [self findMinMax:buffer length:len numChannels:numChannels];
        bytesProcessed += len * sizeof(float);

        if (i % 4 && !self.isCancelled) {
            WEAK_SELF dispatch_async(dispatch_get_main_queue(), ^(void) {
                [weakSelf.delegate audioWaveform:weakSelf didLoadData:((float) i / _numChunks)];
            });
        }
    }

    BASS_StreamFree(_channel);
    free(buffer);

    //    [self normalizeMinMaxValues];

    self.isFinished = YES;

    if (!self.isCancelled) {
        WEAK_SELF dispatch_async(dispatch_get_main_queue(), ^(void) {
            [weakSelf.delegate audioWaveform:weakSelf didLoadData:1];
        });
    }

    dispatch_semaphore_signal(_loaderSemaphore);

}

- (MinMax)getMinMax:(NSUInteger)index {
    if (index < _numChunks) {
        return _waveform[index];
    }
    else {
        return _defaultWaveform;
    }
}

- (MinMax)findMinMax:(float *)buffer length:(NSUInteger)length numChannels:(NSUInteger)channels {
    MinMax result;
    result.max = 0;
    result.min = 0;
    NSUInteger i = 0;
    while (i < length && !self.isCancelled) {
        float value = 0;
        for (int j = 0; j < channels; j++) {
            value = value + buffer[i];
            i++;
        }
        value /= channels;
        if (value > 2 || value < -2) {
//            LogDebug(@"Value out of range: %.4f i: %d", value, i);
        }
        else {
            if (value < result.min) result.min = value;
            if (value > result.max) result.max = value;
        }
    }
    if (isnan(result.min)) {
        LogError(@"min is nan");
    }
    if (isnan(result.max)) {
        LogError(@"max is nan");
    }
    return result;
}


- (void)normalizeMinMaxValues {
    MinMax total;
    for (int i = 0; i < _numChunks && !self.isCancelled; i++) {
        MinMax m = [self getMinMax:i];
        if (m.min < total.min) total.min = m.min;
        if (m.max > total.max) total.max = m.max;
    }
    float factor = fabsf(total.min);
    if (fabsf(total.min) > fabsf(total.max)) {
        factor = fabsf(total.min);
    }
    factor = 1/factor;
    LogDebug(@"normalize: min: %.4f max: %.4f - adjustment factor: %.4f", total.min, total.max, factor);
    for (int i = 0; i < _numChunks && !self.isCancelled; i++) {
        _waveform[i].min = _waveform[i].min * factor;
        _waveform[i].max = _waveform[i].max * factor;
    }
}

- (void)cancel {
    if (self.isFinished || self.isCancelled) {
        return;
    }
    self.isCancelled = YES;
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (2 * NSEC_PER_SEC));
    dispatch_semaphore_wait(_loaderSemaphore, timeout);
}

@end
