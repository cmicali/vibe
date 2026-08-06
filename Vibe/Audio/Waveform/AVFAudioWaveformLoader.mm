//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AVFAudioWaveformLoader.h"
#import "AudioWaveform.h"
#import "AudioBPMAnalyzer.h"
#import <AVFoundation/AVFoundation.h>

#include <vector>

@implementation AVFAudioWaveformLoader

- (CodableAudioWaveform *)load:(NSString *)filename {

    // A cancel may have arrived while this load was queued, so honor it.
    if (self.isCancelled) {
        return nil;
    }

    NSError *error = nil;
    // Interleaved float32, because AudioWaveformMonoMix expects the sample
    // layout L0 R0 L1 R1 and so on.
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:filename]
                                               commonFormat:AVAudioPCMFormatFloat32
                                                interleaved:YES
                                                      error:&error];
    if (!file) {
        LogError(@"AVAudioFile open failed for %@: %@", filename, error);
        return nil;
    }
    if (self.isCancelled) {
        // The open blocked, on a cloud placeholder or a slow mount, and the
        // track changed meanwhile. Skip the decode setup entirely.
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
    // Wrap it immediately so that ARC manages the lifetime. The blocks below
    // capture the result strongly, keeping the waveform alive until every
    // pending callback has fired.
    CodableAudioWaveform *result = [[CodableAudioWaveform alloc] initWithWaveform:waveform];

    NSUInteger numChunks = waveform->getNumChunks();
    if (numChunks == 0) {
        // The chunk-buffer calloc failed, out of memory. Everything downstream
        // divides by the chunk count, so bail out rather than SIGFPE.
        return nil;
    }
    // file.length is exact for every CoreAudio format, so no prescan is
    // needed. Chunk i covers frames [i*T/N, (i+1)*T/N), every frame is
    // scanned, and a normal file always fills exactly numChunks chunks at
    // their final positions, so nothing moves when the load completes. Only a
    // file with fewer frames than chunks decodes short and is stretched
    // afterwards.
    NSUInteger effectiveChunks = totalFrames < (AVAudioFramePosition)numChunks
            ? (NSUInteger)totalFrames
            : numChunks;

    // Read in large blocks and slice the chunks in memory. Chunk-granular
    // reads of 5-10KB, some 8,200 per file, each cross the ExtAudioFile and
    // AudioConverter boundary, and that per-call overhead dominates a cold
    // scan. The output is identical, because min/max merging is associative.
    const AVAudioFrameCount kReadBlockFrames = 65536; // ~512KB stereo float32 per read
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                             frameCapacity:kReadBlockFrames];
    if (!buffer) {
        LogError(@"Could not allocate PCM buffer for %@", filename);
        return nil;
    }

    // Tempo detection rides the same decode pass: the analyzer consumes each
    // buffer right after the waveform chunk does, so BPM never costs a second
    // full-file read, which matters for cloud-backed files.
    AudioBPMAnalyzer *bpmAnalyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate];

    // Scratch for the shared interleaved-to-mono mix. Each decode buffer is
    // downmixed once here and fed to both the waveform chunk and the BPM
    // analyzer. Mono files skip the mix entirely, since AudioWaveformMonoMix
    // returns the buffer itself.
    std::vector<float> monoScratch;
    if (numChannels > 1) {
        monoScratch.resize(kReadBlockFrames);
    }

    CFAbsoluteTime lastProgressTime = 0;
    NSUInteger chunksFilled = 0;
    BOOL readError = NO;

    AVAudioFramePosition framesRead = 0;
    NSUInteger chunkIndex = 0;
    // Proportional boundaries, with a variance of one frame in chunk size:
    // chunk i ends at frame (i+1)*T/N.
    AVAudioFramePosition chunkEnd = totalFrames / (AVAudioFramePosition)effectiveChunks;
    // Accumulates a chunk across block boundaries, since a chunk rarely aligns
    // with a block edge.
    AudioWaveformCacheChunk currentChunk;
    BOOL currentChunkHasFrames = NO;

    while (framesRead < totalFrames && !self.isCancelled) {
        AVAudioFrameCount toRead = (AVAudioFrameCount)MIN(
                (AVAudioFramePosition)kReadBlockFrames, totalFrames - framesRead);
        // A sequential read: AVAudioFile advances its framePosition.
        if (![file readIntoBuffer:buffer frameCount:toRead error:&error]) {
            LogError(@"AVAudioFile read failed at frame %lld of %lld in %@: %@",
                     framesRead, totalFrames, filename, error);
            readError = YES;
            break;
        }
        if (buffer.frameLength == 0) {
            break; // EOF; the completeness thresholds below decide what it means
        }
        NSUInteger numFrames = buffer.frameLength;
        const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], monoScratch.data(),
                                                 numFrames, numChannels);
        [bpmAnalyzer appendMonoSamples:mono frameCount:numFrames];

        // Slice the block at chunk boundaries, merging each segment into the
        // chunk it belongs to.
        NSUInteger offset = 0;
        while (offset < numFrames && chunkIndex < effectiveChunks) {
            AVAudioFramePosition pos = framesRead + (AVAudioFramePosition)offset;
            NSUInteger take = (NSUInteger)MIN((AVAudioFramePosition)(numFrames - offset),
                                              chunkEnd - pos);
            currentChunk.mergeFromMonoBuffer(mono + offset, take);
            currentChunkHasFrames = YES;
            offset += take;
            if (framesRead + (AVAudioFramePosition)offset >= chunkEnd) {
                waveform->setChunkAtIndex(currentChunk, chunkIndex);
                chunksFilled = ++chunkIndex;
                currentChunk = AudioWaveformCacheChunk();
                currentChunkHasFrames = NO;
                chunkEnd = totalFrames * (AVAudioFramePosition)(chunkIndex + 1)
                        / (AVAudioFramePosition)effectiveChunks;
            }
        }
        framesRead += numFrames;

        // Throttle delegate notifications to about 10 Hz, because each one
        // triggers a full path rebuild on the main thread. AudioWaveformCache
        // delivers the final completion callback separately.
        if (!self.isCancelled) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastProgressTime >= 0.1) {
                lastProgressTime = now;
                float percentComplete = (float)chunksFilled / (float)effectiveChunks;
                // Snapshot on the loader thread, the only writer, so that the
                // main thread renders an immutable copy. Reading the live
                // buffer would be a data race, because this loop keeps calling
                // setChunkAtIndex and the stretch pass below remaps it in
                // place.
                CodableAudioWaveform *snapshot = [result snapshot];
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    if (!self.isCancelled) {
                        [self.delegate audioWaveformLoader:self waveform:snapshot didLoadData:percentComplete];
                    }
                });
            }
        }
    }

    // EOF with a partly accumulated chunk: keep it.
    if (currentChunkHasFrames && chunkIndex < effectiveChunks) {
        waveform->setChunkAtIndex(currentChunk, chunkIndex);
        chunksFilled = chunkIndex + 1;
    }
    if (!readError && !self.isCancelled
            && framesRead < totalFrames && chunksFilled + 2 < effectiveChunks) {
        // With exact lengths, EOF lands only right at the end, so ending more
        // than about two chunks early means truncation.
        LogError(@"Audio ended early at chunk %lu of %lu in %@",
                 (unsigned long)chunksFilled, (unsigned long)effectiveChunks, filename);
        readError = YES;
    }

    if (self.isCancelled && chunksFilled < effectiveChunks) {
        // Cancelled mid-decode, so the data really is partial. A cancel that
        // lands after the loop has read every chunk falls through instead: the
        // decode is complete and worth caching for the next play of this
        // track. The cache's delivery site filters cancelled loads out of the
        // UI, so discarding here would only lose that cache write.
        return nil;
    }

    // Match the EOF tolerance above: a read ending up to two chunks short of
    // file.length's claim counts as complete, because a VBR mis-tag or slight
    // truncation over-reports the length. A threshold stricter than the EOF
    // tolerance would leave such files neither errored nor complete — frozen
    // mid-load, never cached, and nothing logged. effectiveChunks is at least
    // 1; guard the unsigned subtraction for tiny files.
    NSUInteger completeThreshold = effectiveChunks > 2 ? effectiveChunks - 2 : 1;
    self.isComplete = !readError && chunksFilled >= completeThreshold;
    if (self.isComplete && chunksFilled < effectiveChunks) {
        LogWarn(@"Waveform for %@ decoded short: %lu of %lu chunks (file length over-reported)",
                filename, (unsigned long)chunksFilled, (unsigned long)effectiveChunks);
    }

    // For a file with fewer frames than chunks, stretch the decoded chunks
    // across the full chunk array, back to front so it is safe in place, so
    // that the waveform spans the full view width rather than leaving a silent
    // tail.
    if (self.isComplete && effectiveChunks < numChunks && chunksFilled > 0) {
        for (NSInteger i = (NSInteger)numChunks - 1; i >= 0; i--) {
            NSUInteger src = (NSUInteger)i * chunksFilled / numChunks;
            waveform->setChunkAtIndex(waveform->getChunkAtIndex(src, numChunks), (NSUInteger)i);
        }
    }
    if (self.isComplete) {
        result.bpm = [bpmAnalyzer finish];
    }
    return result;
}

@end
