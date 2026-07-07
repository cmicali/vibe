//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AVFAudioWaveformLoader.h"
#import <AVFoundation/AVFoundation.h>

@implementation AVFAudioWaveformLoader

- (CodableAudioWaveform *)load:(NSString *)filename {

    // A cancel may have arrived while this load was queued — honor it.
    if (self.isCancelled) {
        return nil;
    }

    NSError *error = nil;
    // Interleaved float32: AudioWaveformCacheChunk::mergeFromAudioBuffer
    // expects L0 R0 L1 R1 ... sample layout.
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:filename]
                                               commonFormat:AVAudioPCMFormatFloat32
                                                interleaved:YES
                                                      error:&error];
    if (!file) {
        LogError(@"AVAudioFile open failed for %@: %@", filename, error);
        return nil;
    }

    AVAudioFramePosition totalFrames = file.length;
    NSUInteger numChannels = file.processingFormat.channelCount;
    if (totalFrames <= 0 || numChannels == 0) {
        LogError(@"AVAudioFile reports no audio in %@ (frames=%lld channels=%lu)",
                 filename, totalFrames, (unsigned long)numChannels);
        return nil;
    }

    AudioWaveform *waveform = new AudioWaveform();
    // Wrap immediately so ARC manages the lifetime. Blocks below capture result
    // strongly, keeping the waveform alive until all pending callbacks fire.
    CodableAudioWaveform *result = [[CodableAudioWaveform alloc] initWithWaveform:waveform];

    NSUInteger numChunks = waveform->getNumChunks();
    // file.length is exact for all CoreAudio formats — no prescan needed.
    // Chunk i covers frames [i*T/N, (i+1)*T/N): every frame is scanned and a
    // normal file always fills exactly numChunks chunks at their final
    // positions, so nothing moves when the load completes. Only files with
    // fewer frames than chunks decode short and get stretched afterwards.
    NSUInteger effectiveChunks = totalFrames < (AVAudioFramePosition)numChunks
            ? (NSUInteger)totalFrames
            : numChunks;
    // Proportional boundaries vary chunk sizes by ±1 frame.
    AVAudioFrameCount maxFramesPerChunk =
            (AVAudioFrameCount)(totalFrames / (AVAudioFramePosition)effectiveChunks) + 1;

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                             frameCapacity:maxFramesPerChunk];
    if (!buffer) {
        LogError(@"Could not allocate PCM buffer for %@", filename);
        return nil;
    }

    CFAbsoluteTime lastProgressTime = 0;
    NSUInteger chunksFilled = 0;
    BOOL readError = NO;

    for (NSUInteger i = 0; i < effectiveChunks && !self.isCancelled; i++) {
        AVAudioFramePosition chunkStart = totalFrames * (AVAudioFramePosition)i / (AVAudioFramePosition)effectiveChunks;
        AVAudioFramePosition chunkEnd = totalFrames * (AVAudioFramePosition)(i + 1) / (AVAudioFramePosition)effectiveChunks;
        AVAudioFrameCount chunkFrames = (AVAudioFrameCount)(chunkEnd - chunkStart);
        // Sequential read — AVAudioFile advances its framePosition.
        if (![file readIntoBuffer:buffer frameCount:chunkFrames error:&error]) {
            LogError(@"AVAudioFile read failed at chunk %lu of %lu: %@",
                     (unsigned long)i, (unsigned long)effectiveChunks, error);
            readError = YES;
            break;
        }
        if (buffer.frameLength == 0) {
            // End of file. With exact lengths this only happens on the very
            // last chunk (integer-division rounding); earlier means truncation.
            if (i + 2 < effectiveChunks) {
                LogError(@"Audio ended early at chunk %lu of %lu in %@",
                         (unsigned long)i, (unsigned long)effectiveChunks, filename);
                readError = YES;
            }
            break;
        }
        AudioWaveformCacheChunk chunk(buffer.floatChannelData[0],
                                      (NSUInteger)buffer.frameLength * numChannels,
                                      numChannels);
        waveform->setChunkAtIndex(chunk, i);
        chunksFilled = i + 1;

        // Throttle delegate notifications to ~10 Hz — each one triggers a
        // full path rebuild on the main thread. The final completion
        // callback is delivered separately by AudioWaveformCache.
        if (!self.isCancelled) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastProgressTime >= 0.1) {
                lastProgressTime = now;
                float percentComplete = (float)i / (float)effectiveChunks;
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

    if (self.isCancelled) {
        return nil;
    }

    self.isComplete = !readError && chunksFilled >= effectiveChunks - 1;

    // Sub-chunk-count files: stretch the decoded chunks across the full chunk
    // array (back to front so it's safe in place) so the waveform spans the
    // full view width instead of leaving a silent tail.
    if (self.isComplete && effectiveChunks < numChunks && chunksFilled > 0) {
        for (NSInteger i = (NSInteger)numChunks - 1; i >= 0; i--) {
            NSUInteger src = (NSUInteger)i * chunksFilled / numChunks;
            waveform->setChunkAtIndex(waveform->getChunkAtIndex(src, numChunks), (NSUInteger)i);
        }
    }
    return result;
}

@end
