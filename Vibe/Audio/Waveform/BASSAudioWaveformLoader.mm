//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BASSAudioWaveformLoader.h"
#import "BassWrapper.h"

@implementation BASSAudioWaveformLoader

- (CodableAudioWaveform *)load:(NSString *)filename {

    self.isCancelled = NO;
    self.isComplete = NO;

    HCHANNEL channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE | BASS_STREAM_PRESCAN);
    if (!channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
        return nil;
    }

    AudioWaveform *waveform = new AudioWaveform();
    // Wrap immediately so ARC manages the lifetime. Blocks below capture result
    // strongly, keeping the waveform alive until all pending callbacks fire.
    CodableAudioWaveform *result = [[CodableAudioWaveform alloc] initWithWaveform:waveform];

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(channel, &info);
    NSUInteger numChannels = info.chans;
    NSUInteger numChunks = waveform->getNumChunks();
    NSUInteger totalBytes = BASS_ChannelGetLength(channel, BASS_POS_BYTE);
    NSUInteger chunkSize = totalBytes / numChunks;

    AlignSizeToTypeBoundary(chunkSize, float);

    float *buffer = (float*)malloc(chunkSize);

    NSUInteger updateBytesCounter = 0;
    NSUInteger updateBytesLimit = totalBytes / 128;

    for (NSUInteger i = 0; i < numChunks && !self.isCancelled; i++) {
        // Sequential read — no seeking needed, BASS advances the decode position
        DWORD bytesRead = BASS_ChannelGetData(channel, buffer, (DWORD)chunkSize);
        if (bytesRead == (DWORD)-1) {
            break;
        }
        NSUInteger bytesToMerge = min(chunkSize, (NSUInteger)bytesRead);
        AudioWaveformCacheChunk chunk(buffer, bytesToMerge/sizeof(float), numChannels);
        waveform->setChunkAtIndex(chunk, i);
        updateBytesCounter += bytesToMerge;
        if (!self.isCancelled && updateBytesCounter >= updateBytesLimit) {
            updateBytesCounter = 0;
            float percentComplete = (float)i / (float)numChunks;
            if (percentComplete < 1.0) {
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    if (!self.isCancelled) {
                        // result is captured strongly, keeping waveform alive
                        [self.delegate audioWaveformLoader:self waveform:result.waveform didLoadData:percentComplete];
                    }
                });
            }
        }
    }

    BASS_StreamFree(channel);
    free(buffer);

    if (self.isCancelled) {
        return nil;
    }

    self.isComplete = YES;
    return result;

}

@end
