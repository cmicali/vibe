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

    // A cancel may have arrived while this load was queued — honor it.
    if (self.isCancelled) {
        return nil;
    }

    NSError *error = nil;
    // Interleaved float32: AudioWaveformMonoMix expects L0 R0 L1 R1 ...
    // sample layout.
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:filename]
                                               commonFormat:AVAudioPCMFormatFloat32
                                                interleaved:YES
                                                      error:&error];
    if (!file) {
        LogError(@"AVAudioFile open failed for %@: %@", filename, error);
        return nil;
    }
    if (self.isCancelled) {
        // The open blocked (cloud placeholder, slow mount) and the track
        // changed in the meantime — skip the decode setup entirely.
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
    if (numChunks == 0) {
        // Chunk-buffer calloc failed (OOM) — everything downstream divides by
        // the chunk count, so bail rather than SIGFPE.
        return nil;
    }
    // file.length is exact for all CoreAudio formats — no prescan needed.
    // Chunk i covers frames [i*T/N, (i+1)*T/N): every frame is scanned and a
    // normal file always fills exactly numChunks chunks at their final
    // positions, so nothing moves when the load completes. Only files with
    // fewer frames than chunks decode short and get stretched afterwards.
    NSUInteger effectiveChunks = totalFrames < (AVAudioFramePosition)numChunks
            ? (NSUInteger)totalFrames
            : numChunks;

    // Read in large blocks and slice chunks in memory: chunk-granular reads
    // (~5-10KB, ~8200 per file) each cross the ExtAudioFile/AudioConverter
    // boundary, and that per-call overhead dominates cold scans. Output is
    // identical — min/max merging is associative.
    const AVAudioFrameCount kReadBlockFrames = 65536; // ~512KB stereo float32 per read
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                             frameCapacity:kReadBlockFrames];
    if (!buffer) {
        LogError(@"Could not allocate PCM buffer for %@", filename);
        return nil;
    }

    // Tempo detection rides the same decode pass — the analyzer consumes each
    // buffer right after the waveform chunk does, so BPM never costs a second
    // full-file read (which matters for cloud-backed files).
    AudioBPMAnalyzer *bpmAnalyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate];

    // Scratch for the shared interleaved→mono mix: each decode buffer is
    // downmixed once here and fed to both the waveform chunk and the BPM
    // analyzer. Mono files skip the mix entirely — AudioWaveformMonoMix
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
    // Proportional boundaries (±1 frame chunk-size variance): chunk i ends
    // at frame (i+1)*T/N.
    AVAudioFramePosition chunkEnd = totalFrames / (AVAudioFramePosition)effectiveChunks;
    // Accumulates a chunk across block boundaries (a chunk rarely aligns
    // with a block edge).
    AudioWaveformCacheChunk currentChunk;
    BOOL currentChunkHasFrames = NO;

    while (framesRead < totalFrames && !self.isCancelled) {
        AVAudioFrameCount toRead = (AVAudioFrameCount)MIN(
                (AVAudioFramePosition)kReadBlockFrames, totalFrames - framesRead);
        // Sequential read — AVAudioFile advances its framePosition.
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

        // Throttle delegate notifications to ~10 Hz — each one triggers a
        // full path rebuild on the main thread. The final completion
        // callback is delivered separately by AudioWaveformCache.
        if (!self.isCancelled) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastProgressTime >= 0.1) {
                lastProgressTime = now;
                float percentComplete = (float)chunksFilled / (float)effectiveChunks;
                // Snapshot on the loader thread (the only writer) so the
                // main thread renders an immutable copy — reading the live
                // buffer while this loop keeps calling setChunkAtIndex, and
                // the stretch pass below remaps it in place, is a data race.
                CodableAudioWaveform *snapshot = [result snapshot];
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    if (!self.isCancelled) {
                        [self.delegate audioWaveformLoader:self waveform:snapshot didLoadData:percentComplete];
                    }
                });
            }
        }
    }

    // EOF with a partially-accumulated chunk: keep it.
    if (currentChunkHasFrames && chunkIndex < effectiveChunks) {
        waveform->setChunkAtIndex(currentChunk, chunkIndex);
        chunksFilled = chunkIndex + 1;
    }
    if (!readError && !self.isCancelled
            && framesRead < totalFrames && chunksFilled + 2 < effectiveChunks) {
        // With exact lengths EOF only lands right at the end; ending more
        // than ~2 chunks early means truncation.
        LogError(@"Audio ended early at chunk %lu of %lu in %@",
                 (unsigned long)chunksFilled, (unsigned long)effectiveChunks, filename);
        readError = YES;
    }

    if (self.isCancelled && chunksFilled < effectiveChunks) {
        // Cancelled mid-decode — the data really is partial. A cancel that
        // lands after the loop read every chunk falls through instead: the
        // decode is complete and worth caching for the next play of this
        // track (the cache's delivery site filters cancelled loads out of
        // the UI; discarding here would only lose that cache write).
        return nil;
    }

    // Match the EOF tolerance above: a read that ends up to 2 chunks short of
    // file.length's claim is treated as complete (VBR mis-tags / slight
    // truncation over-report the length). A stricter threshold here than the
    // EOF tolerance would leave such files neither errored nor complete —
    // frozen mid-load, never cached, nothing logged.
    // (effectiveChunks >= 1; guard the unsigned subtraction for tiny files.)
    NSUInteger completeThreshold = effectiveChunks > 2 ? effectiveChunks - 2 : 1;
    self.isComplete = !readError && chunksFilled >= completeThreshold;
    if (self.isComplete && chunksFilled < effectiveChunks) {
        LogWarn(@"Waveform for %@ decoded short: %lu of %lu chunks (file length over-reported)",
                filename, (unsigned long)chunksFilled, (unsigned long)effectiveChunks);
    }

    // Sub-chunk-count files: stretch the decoded chunks across the full chunk
    // array (back to front so it's safe in place) so the waveform spans the
    // full view width instead of leaving a silent tail.
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
