//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"
#import "BassWrapper.h"

#define SIZE            512
#define UPDATE_RATE     8

@implementation AudioWaveform {
    MinMax _waveform[SIZE];
    dispatch_semaphore_t _loaderSemaphore;
}

- (id)init {
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        [self setup];
        NSUInteger length;
        const uint8_t *bytes = [coder decodeBytesForKey:@"_waveform" returnedLength:&length];
        memcpy(_waveform, bytes, length);
        self.isFinished = YES;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    NSUInteger numBytes = SIZE * sizeof(MinMax);
    [coder encodeBytes:reinterpret_cast<const uint8_t *>(_waveform) length:numBytes forKey:@"_waveform"];
}

- (void)setup {
    _loaderSemaphore = dispatch_semaphore_create(0);
    self.isCancelled = NO;
    self.isFinished = NO;
    for (int i = 0; i < SIZE; ++i) {
        _waveform[i].min = 0;
        _waveform[i].max = 0;
    }
}

- (BOOL)load:(NSString *)filename {

    self.isCancelled = NO;
    self.isFinished = NO;

    HCHANNEL channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_STREAM_PRESCAN);
    if (!channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
        return NO;
    }

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(channel, &info);
    NSUInteger numChannels = info.chans;

    NSUInteger totalBytes = BASS_ChannelGetLength(channel, BASS_POS_BYTE);
    uint32_t chunkSize = uint32_t(totalBytes / SIZE);

    // Align to float boundary
    if (chunkSize % sizeof(float) != 0)
        chunkSize += sizeof(float) - chunkSize % sizeof(float);

    uint32_t readChunkSize = chunkSize + 2048;
    float *buffer = (float*)malloc(readChunkSize);

    uint32_t bytesProcessed = 0;

    for (int i = 0; i < SIZE && !self.isCancelled; i++) {
        BASS_ChannelSetPosition(channel, bytesProcessed, BASS_POS_BYTE);
        int bytesRead = BASS_ChannelGetData(channel, buffer, readChunkSize);
        int len = min(chunkSize, bytesRead);
        _waveform[i] = [self findMinMax:buffer length:len/sizeof(float) numChannels:numChannels];
        bytesProcessed += len;
        float percentComplete = ((float) i / SIZE);
        if (i % UPDATE_RATE && !self.isCancelled && percentComplete != 1.0) {
            WEAK_SELF dispatch_async(dispatch_get_main_queue(), ^(void) {
                [weakSelf.delegate audioWaveform:weakSelf didLoadData:percentComplete];
            });
        }
    }

    BASS_StreamFree(channel);
    free(buffer);

    //    [self normalizeMinMaxValues];

    self.isFinished = YES;

    if (!self.isCancelled) {
        WEAK_SELF dispatch_async(dispatch_get_main_queue(), ^(void) {
            [weakSelf.delegate audioWaveform:weakSelf didLoadData:1];
        });
    }

    dispatch_semaphore_signal(_loaderSemaphore);

    return YES;
}

- (MinMax)getMinMax:(NSUInteger)index {
    if (index < SIZE) {
        return _waveform[index];
    }
    else {
        MinMax m; m.min = 0; m.max = 0;
        return m;
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
    for (int i = 0; i < SIZE && !self.isCancelled; i++) {
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
    for (int i = 0; i < SIZE && !self.isCancelled; i++) {
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
