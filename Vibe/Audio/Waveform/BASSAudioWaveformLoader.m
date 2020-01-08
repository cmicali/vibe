//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BASSAudioWaveformLoader.h"
#import "BassWrapper.h"

@implementation BASSAudioWaveformLoader

- (AudioWaveformOld *)load:(NSString *)filename {

    self.isCancelled = NO;
    self.isFinished = NO;

    HCHANNEL channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_STREAM_PRESCAN);
    if (!channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
        return nil;
    }

    AudioWaveformOld *waveform = [[AudioWaveformOld alloc] init];

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(channel, &info);
    NSUInteger numChannels = info.chans;

    NSUInteger totalBytes = BASS_ChannelGetLength(channel, BASS_POS_BYTE);
    NSUInteger chunkSize = totalBytes / waveform.count;

    AlignSizeToTypeBoundary(chunkSize, float);

    NSUInteger readChunkSize = chunkSize + 2048;
    float *buffer = (float*)malloc(readChunkSize);

    NSUInteger bytesProcessed = 0;
    NSUInteger updateBytesCounter = 0;
    NSUInteger numUpdates = 128;
    NSUInteger updateBytesLimit = totalBytes / numUpdates;

    for (int i = 0; i < waveform.count && !self.isCancelled; i++) {
        BASS_ChannelSetPosition(channel, bytesProcessed, BASS_POS_BYTE);
        NSUInteger bytesRead = BASS_ChannelGetData(channel, buffer, (DWORD)readChunkSize);
        NSUInteger len = min(chunkSize, bytesRead);
        AudioWaveformCacheChunk chunk = [self getChunkForAudioBuffer:buffer length:len/sizeof(float) numChannels:numChannels];
        [waveform setChunk:chunk atIndex:i];
        bytesProcessed += len;
        updateBytesCounter += len;
        float percentComplete = ((float) i / waveform.count);
        if (!self.isCancelled && percentComplete != 1.0 && updateBytesCounter >= updateBytesLimit) {
            updateBytesCounter = 0;
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [self.delegate audioWaveformLoader:self waveform:waveform didLoadData:percentComplete];
            });
        }
    }

    BASS_StreamFree(channel);
    free(buffer);

    self.isFinished = YES;

    return waveform;

}

@end
