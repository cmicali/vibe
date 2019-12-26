//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <sys/stat.h>
#import "AudioWaveform.h"
#import "AudioPlayer.h"


@implementation AudioWaveform {

    float *_samples;
    QWORD _numBytes;
    DWORD _numChannels;

    NSUInteger _size;
    NSMutableArray *_minValues;
    NSMutableArray *_maxValues;

    HSTREAM _channel;
    FILE *_file;
}

void CALLBACK CChannelEndedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    LogDebug(@"Channel ended");
}

void CALLBACK CDownloadFinishedCallback(HSYNC handle, DWORD channel, DWORD data, void *user)  {
    LogDebug(@"Download finished");
}

void CALLBACK MyFileCloseProc(void *user) {
    AudioWaveform *waveform = (__bridge AudioWaveform *)user;
    fclose(waveform->_file); // close the file
    waveform->_file = nil;
    LogDebug(@"file: close");
}

QWORD CALLBACK MyFileLenProc(void *user) {
    AudioWaveform *waveform = (__bridge AudioWaveform *)user;
    struct stat s;
    fstat(fileno(waveform->_file), &s);
    LogDebug(@"file: len: %d", s.st_size);
    return s.st_size; // return the file length
}

DWORD CALLBACK MyFileReadProc(void *buffer, DWORD length, void *user) {
    AudioWaveform *waveform = (__bridge AudioWaveform *)user;
    int64_t bytes = BASS_ChannelGetLength(waveform->_channel, BASS_POS_BYTE);
//    int32_t bytesRead = 0;
//    if (bytes > 0) {
//        waveform->_numBytes = bytes;
//        if (waveform->_samples == nil) {
//            waveform->_samples = malloc(bytes);
//        }
//        bytesRead = BASS_ChannelGetData(waveform->_channel, waveform->_samples, BASS_DATA_AVAILABLE);
//    }
    LogDebug(@"file: read: %d\t\ttotal: %d", length, bytes);
    return fread(buffer, 1, length, waveform->_file); // read from file
}

BOOL CALLBACK MyFileSeekProc(QWORD offset, void *user) {
    AudioWaveform *waveform = (__bridge AudioWaveform *)user;
    LogDebug(@"file: seek: %d", offset);
    return !fseek(waveform->_file, offset, SEEK_SET); // seek to offset
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
    TIME_START(@"File load")
    LogDebug(@"Loading %@", filename);

//    BASS_FILEPROCS fileprocs = { MyFileCloseProc, MyFileLenProc, MyFileReadProc, MyFileSeekProc }; // callback table
//    _file = fopen([filename cStringUsingEncoding:NSUTF8StringEncoding], "rb");

    _channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_ASYNCFILE);

//    _channel = BASS_StreamCreateFileUser(STREAMFILE_BUFFER,
//                                         BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_ASYNCFILE,
//                                         &fileprocs, (__bridge void *)self);

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
    TIME_END
    TIME_RESTART(@"minmaxing")
    [self calculateMinMax];
    TIME_END
    TIME_RESTART(@"normalizing")
    [self normalizeMinMaxValues];
    TIME_END
    TIME_RESTART(@"cleanup")
    BASS_StreamFree(_channel);
    free(_samples);
    TIME_END
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
    result.max = 0;
    result.min = 0;
    NSUInteger i = 0;
    while (i < length) {
        float value = 0;
        for (int j = 0; j < _numChannels; j++) {
            value = value + buffer[i];
            i++;
        }
        value /= _numChannels;
        if (value < result.min) result.min = value;
        if (value > result.max) result.max = value;
    }
    if (isnan(result.min)) {
        LogError(@"min is nan");
    }
    if (isnan(result.max)) {
        LogError(@"max is nan");
    }
    return result;
}

- (void)calculateMinMax {
    NSMutableArray *minResult = [[NSMutableArray alloc] initWithCapacity:_size];
    NSMutableArray *maxResult = [[NSMutableArray alloc] initWithCapacity:_size];
    NSUInteger chunkSize = _numBytes / sizeof(float) / _size;
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

- (void)normalizeMinMaxValues {
    MinMax total;
    for (int i = 0; i < _size; i++) {
        MinMax m = [self getMinMax:i];
        if (m.min < total.min) total.min = m.min;
        if (m.max > total.max) total.max = m.max;
    }
    double factor = fabs(total.min);
    if (fabs(total.min) > fabs(total.max)) {
        factor = fabs(total.min);
    }
    factor = 1/factor;
    LogDebug(@"normalize: min: %.4f max: %.4f - adjustment factor: %.4f", total.min, total.max, factor);
    for (int i = 0; i < _size; i++) {
        _minValues[i] = @([((NSNumber *)_minValues[i]) floatValue] * factor);
        _maxValues[i] = @([((NSNumber *)_maxValues[i]) floatValue] * factor);
    }
}

@end