//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BASSAudioWaveformLoader.h"
#import "BassWrapper.h"

@implementation BASSAudioWaveformLoader

- (CodableAudioWaveform *)load:(NSString *)filename {

    // A cancel may have arrived while this load was queued — honor it.
    if (self.isCancelled) {
        return nil;
    }

    // PRESCAN reads the whole file once just to get an exact length, doubling
    // a load's I/O. Only MP3 needs it (VBR length estimates can be far off);
    // FLAC/MP4/WAV/AIFF report exact lengths without it.
    DWORD flags = BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE;
    if ([[filename.pathExtension lowercaseString] isEqualToString:@"mp3"]) {
        flags |= BASS_STREAM_PRESCAN;
    }
    HCHANNEL channel = BASS_StreamCreateFile(NO, [filename cStringUsingEncoding:NSUTF8StringEncoding], 0, 0, flags);
    if (!channel) {
        LogError(@"BASS_StreamCreateFile error: %d", BASS_ErrorGetCode());
        return nil;
    }

    BASS_CHANNELINFO info;
    BASS_ChannelGetInfo(channel, &info);
    NSUInteger numChannels = info.chans;
    QWORD lengthBytes = BASS_ChannelGetLength(channel, BASS_POS_BYTE);
    if (lengthBytes == (QWORD)-1) {
        LogError(@"BASS_ChannelGetLength error: %d", BASS_ErrorGetCode());
        BASS_StreamFree(channel);
        return nil;
    }

    AudioWaveform *waveform = new AudioWaveform();
    // Wrap immediately so ARC manages the lifetime. Blocks below capture result
    // strongly, keeping the waveform alive until all pending callbacks fire.
    CodableAudioWaveform *result = [[CodableAudioWaveform alloc] initWithWaveform:waveform];

    NSUInteger numChunks = waveform->getNumChunks();
    NSUInteger totalBytes = (NSUInteger)lengthBytes;
    NSUInteger chunkSize = totalBytes / numChunks;

    AlignSizeToTypeBoundary(chunkSize, float);

    float *buffer = (float*)malloc(chunkSize);
    if (!buffer) {
        BASS_StreamFree(channel);
        return nil;
    }

    NSUInteger updateBytesCounter = 0;
    NSUInteger updateBytesLimit = totalBytes / 128;
    CFAbsoluteTime lastProgressTime = 0;

    NSUInteger chunksFilled = 0;
    BOOL readError = NO;
    BOOL streamEnded = NO;
    for (NSUInteger i = 0; i < numChunks && !self.isCancelled; i++) {
        // Sequential read — no seeking needed, BASS advances the decode position
        DWORD bytesRead = BASS_ChannelGetData(channel, buffer, (DWORD)chunkSize);
        if (bytesRead == (DWORD)-1) {
            int err = BASS_ErrorGetCode();
            if (err == BASS_ERROR_ENDED) {
                // chunkSize is rounded up to a float boundary, so on most files
                // the last chunk runs slightly past end-of-stream. That's only
                // legitimate within the final couple of chunks — an earlier end
                // means a truncated file, which must not be cached as complete.
                if (i + 2 >= numChunks) {
                    streamEnded = YES;
                } else {
                    LogError(@"BASS stream ended early at chunk %lu of %lu", (unsigned long)i, (unsigned long)numChunks);
                    readError = YES;
                }
                break;
            }
            LogError(@"BASS_ChannelGetData failed at chunk %lu: %d", (unsigned long)i, err);
            readError = YES;
            break;
        }
        NSUInteger bytesToMerge = min(chunkSize, (NSUInteger)bytesRead);
        AudioWaveformCacheChunk chunk(buffer, bytesToMerge/sizeof(float), numChannels);
        waveform->setChunkAtIndex(chunk, i);
        chunksFilled = i + 1;
        updateBytesCounter += bytesToMerge;
        if (!self.isCancelled && updateBytesCounter >= updateBytesLimit) {
            updateBytesCounter = 0;
            // Throttle delegate notifications to ~10 Hz — each one triggers a
            // full path rebuild on the main thread. The final completion
            // callback is delivered separately by AudioWaveformCache.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastProgressTime >= 0.1) {
                lastProgressTime = now;
                float percentComplete = (float)i / (float)numChunks;
                if (percentComplete < 1.0) {
                    dispatch_async(dispatch_get_main_queue(), ^(void) {
                        if (!self.isCancelled) {
                            [self.delegate audioWaveformLoader:self waveform:result didLoadData:percentComplete];
                        }
                    });
                }
            }
        }
    }

    BASS_StreamFree(channel);
    free(buffer);

    if (self.isCancelled) {
        return nil;
    }

    self.isComplete = !readError && (streamEnded || chunksFilled == numChunks);
    return result;

}

@end
