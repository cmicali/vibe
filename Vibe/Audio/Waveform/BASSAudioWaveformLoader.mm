//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BASSAudioWaveformLoader.h"
#import "BassWrapper.h"

@implementation BASSAudioWaveformLoader

- (AudioWaveform *)load:(NSString *)filename {

    self.isCancelled = NO;
    self.isComplete = NO;

    HCHANNEL channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_STREAM_PRESCAN);
    if (!channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
        return nil;
    }

    AudioWaveform *waveform = new AudioWaveform();

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(channel, &info);
    NSUInteger numChannels = info.chans;
    NSUInteger numChunks = waveform->getNumChunks();
    NSUInteger totalBytes = BASS_ChannelGetLength(channel, BASS_POS_BYTE);
    NSUInteger chunkSize = totalBytes / numChunks;

    AlignSizeToTypeBoundary(chunkSize, float);

    NSUInteger readChunkSize = chunkSize + 4096;
    float *buffer = (float*)malloc(readChunkSize);

    NSUInteger bytesProcessed = 0;
    NSUInteger updateBytesCounter = 0;
    NSUInteger numUpdates = 128;
    NSUInteger updateBytesLimit = totalBytes / numUpdates;

    for (NSUInteger i = 0; i < numChunks && !self.isCancelled; i++) {
        BASS_ChannelSetPosition(channel, bytesProcessed, BASS_POS_BYTE);
        NSUInteger bytesRead = BASS_ChannelGetData(channel, buffer, (DWORD)readChunkSize);
        NSUInteger bytesToMerge = min(chunkSize, bytesRead);
        AudioWaveformCacheChunk chunk(buffer, bytesToMerge/sizeof(float), numChannels);
        waveform->setChunkAtIndex(chunk, i);
        bytesProcessed += bytesToMerge;
        updateBytesCounter += bytesToMerge;
        if (!self.isCancelled &&  updateBytesCounter >= updateBytesLimit) {
            updateBytesCounter = 0;
            float percentComplete = (float)i / (float)numChunks;
            if (percentComplete < 1.0) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    [self.delegate audioWaveformLoader:self waveform:waveform didLoadData:percentComplete];
                });
            }
        }
    }

    if (!self.isCancelled) {
        self.isComplete = YES;
    }

    BASS_StreamFree(channel);
    free(buffer);

    return waveform;

}

@end
