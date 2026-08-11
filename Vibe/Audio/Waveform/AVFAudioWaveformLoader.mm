//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AVFAudioWaveformLoader.h"
#import "AudioWaveform.h"
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
#import "AudioLoadTiming.h"
#import <AVFoundation/AVFoundation.h>

#include <vector>

@implementation AVFAudioWaveformLoader

- (CodableAudioWaveform *)load:(NSString *)filename {

    // Phase timings for this pass. The clock reads compile to constants in
    // Release, where nothing consumes them; see AudioLoadTiming.h.
    VibeLoadPhaseNanos nanos = {};
    uint64_t loadStart = VibeLoadClockNow();

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
    //
    // Two buffers, because the decode and the processing are pipelined: block
    // N+1 decodes on this thread while block N runs through the mono mix, the
    // analyzers and the chunker on a serial queue one block behind. The pass
    // is decode-bound — CoreAudio's MP3 and FLAC codecs cost 3-5x everything
    // downstream combined — so overlapping them takes the wall time down to
    // roughly the decode alone, 12-17% measured with both analyzers on. A
    // slot's buffer is reused only after its semaphore signals, so the decode
    // never writes a buffer the processor is still reading, and the serial
    // queue preserves stream order, which the analyzers' framing depends on.
    const AVAudioFrameCount kReadBlockFrames = 65536; // ~512KB stereo float32 per read
    AVAudioPCMBuffer *buffers[2];
    buffers[0] = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                               frameCapacity:kReadBlockFrames];
    buffers[1] = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                               frameCapacity:kReadBlockFrames];
    if (!buffers[0] || !buffers[1]) {
        LogError(@"Could not allocate PCM buffers for %@", filename);
        return nil;
    }

    // Tempo and key detection ride the same decode pass: each analyzer
    // consumes the buffer right after the waveform chunk does, so neither
    // costs a second full-file read, which matters for cloud-backed files.
    // With a setting off there is no analyzer, and the waveform caches with
    // no BPM or key — a file scanned while off is not re-analyzed on
    // re-enable until its cache entry goes. The explicit scan_bpm and
    // scan_key debug paths run the analyzers directly and ignore this.
    AudioBPMAnalyzer *bpmAnalyzer = Settings.analyzeBPM
            ? [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate]
            : nil;
    AudioKeyAnalyzer *keyAnalyzer = Settings.analyzeKey
            ? [[AudioKeyAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate]
            : nil;

    // Scratch for the shared interleaved-to-mono mix, one per pipeline slot.
    // Each decode buffer is downmixed once and fed to both the waveform chunk
    // and the analyzers. Mono files skip the mix entirely, since
    // AudioWaveformMonoMix returns the buffer itself.
    std::vector<float> monoScratches[2];
    if (numChannels > 1) {
        monoScratches[0].resize(kReadBlockFrames);
        monoScratches[1].resize(kReadBlockFrames);
    }

    // Everything the processing blocks touch. They run one at a time on the
    // serial queue and the decode loop never reads these until the final
    // drain, so no lock is needed. The phase accumulators are split by
    // ownership for the same reason: the processing side writes procNanos,
    // the decode loop writes only nanos.read.
    dispatch_queue_t processQueue = dispatch_queue_create("com.vibe.waveform.process",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    __block VibeLoadPhaseNanos procNanos = {};
    __block CFAbsoluteTime lastProgressTime = 0;
    __block NSUInteger chunksFilled = 0;
    __block NSUInteger chunkIndex = 0;
    __block AVAudioFramePosition framesProcessed = 0;
    // Proportional boundaries, with a variance of one frame in chunk size:
    // chunk i ends at frame (i+1)*T/N.
    __block AVAudioFramePosition chunkEnd = totalFrames / (AVAudioFramePosition)effectiveChunks;
    // Accumulates a chunk across block boundaries, since a chunk rarely aligns
    // with a block edge.
    __block AudioWaveformCacheChunk currentChunk;
    __block BOOL currentChunkHasFrames = NO;

    dispatch_semaphore_t slotFree[2] = { dispatch_semaphore_create(1), dispatch_semaphore_create(1) };
    int slot = 0;
    BOOL readError = NO;
    AVAudioFramePosition framesRead = 0;

    while (framesRead < totalFrames && !self.isCancelled) {
        // Wait for this slot's previous processing to finish before reusing
        // its buffer. With two slots the decode runs at most one block ahead.
        dispatch_semaphore_wait(slotFree[slot], DISPATCH_TIME_FOREVER);
        AVAudioPCMBuffer *buffer = buffers[slot];
        float *scratch = monoScratches[slot].data();

        AVAudioFrameCount toRead = (AVAudioFrameCount)MIN(
                (AVAudioFramePosition)kReadBlockFrames, totalFrames - framesRead);
        // A sequential read: AVAudioFile advances its framePosition.
        uint64_t phaseStart = VibeLoadClockNow();
        BOOL readOK = [file readIntoBuffer:buffer frameCount:toRead error:&error];
        nanos.read += VibeLoadClockNow() - phaseStart;
        if (!readOK) {
            LogError(@"AVAudioFile read failed at frame %lld of %lld in %@: %@",
                     framesRead, totalFrames, filename, error);
            readError = YES;
            dispatch_semaphore_signal(slotFree[slot]);
            break;
        }
        if (buffer.frameLength == 0) {
            // EOF; the completeness thresholds below decide what it means.
            dispatch_semaphore_signal(slotFree[slot]);
            break;
        }
        NSUInteger numFrames = buffer.frameLength;
        framesRead += numFrames;

        dispatch_semaphore_t slotDone = slotFree[slot];
        dispatch_async(processQueue, ^{
            // The downmix counts as baseline: the chunker needs it whether or
            // not an analyzer is running.
            uint64_t procStart = VibeLoadClockNow();
            const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], scratch,
                                                     numFrames, numChannels);
            procNanos.chunk += VibeLoadClockNow() - procStart;

            procStart = VibeLoadClockNow();
            [bpmAnalyzer appendMonoSamples:mono frameCount:numFrames];
            procNanos.bpmAppend += VibeLoadClockNow() - procStart;
            procStart = VibeLoadClockNow();
            [keyAnalyzer appendMonoSamples:mono frameCount:numFrames];
            procNanos.keyAppend += VibeLoadClockNow() - procStart;

            // Slice the block at chunk boundaries, merging each segment into
            // the chunk it belongs to.
            procStart = VibeLoadClockNow();
            NSUInteger offset = 0;
            while (offset < numFrames && chunkIndex < effectiveChunks) {
                AVAudioFramePosition pos = framesProcessed + (AVAudioFramePosition)offset;
                NSUInteger take = (NSUInteger)MIN((AVAudioFramePosition)(numFrames - offset),
                                                  chunkEnd - pos);
                currentChunk.mergeFromMonoBuffer(mono + offset, take);
                currentChunkHasFrames = YES;
                offset += take;
                if (framesProcessed + (AVAudioFramePosition)offset >= chunkEnd) {
                    waveform->setChunkAtIndex(currentChunk, chunkIndex);
                    chunksFilled = ++chunkIndex;
                    currentChunk = AudioWaveformCacheChunk();
                    currentChunkHasFrames = NO;
                    chunkEnd = totalFrames * (AVAudioFramePosition)(chunkIndex + 1)
                            / (AVAudioFramePosition)effectiveChunks;
                }
            }
            procNanos.chunk += VibeLoadClockNow() - procStart;
            framesProcessed += numFrames;

            // Throttle delegate notifications to about 10 Hz, because each one
            // triggers a full path rebuild on the main thread.
            // AudioWaveformCache delivers the final completion callback
            // separately.
            if (!self.isCancelled) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastProgressTime >= 0.1) {
                    lastProgressTime = now;
                    float percentComplete = (float)chunksFilled / (float)effectiveChunks;
                    // Snapshot on this queue, the only writer, so that the
                    // main thread renders an immutable copy. Reading the live
                    // buffer would be a data race, because this queue keeps
                    // calling setChunkAtIndex and the stretch pass below
                    // remaps it in place.
                    CodableAudioWaveform *snapshot = [result snapshot];
                    dispatch_async(dispatch_get_main_queue(), ^(void) {
                        if (!self.isCancelled) {
                            [self.delegate audioWaveformLoader:self waveform:snapshot didLoadData:percentComplete];
                        }
                    });
                }
            }
            dispatch_semaphore_signal(slotDone);
        });
        slot ^= 1;
    }
    // Drain the pipeline. After this the processing state above is safe to
    // read and the pass is single-threaded again.
    dispatch_sync(processQueue, ^{});
    nanos.chunk = procNanos.chunk;
    nanos.bpmAppend = procNanos.bpmAppend;
    nanos.keyAppend = procNanos.keyAppend;

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
    if (self.isComplete && bpmAnalyzer) {
        uint64_t phaseStart = VibeLoadClockNow();
        result.bpm = [bpmAnalyzer finish];
        nanos.bpmFinish = VibeLoadClockNow() - phaseStart;
    }
    if (self.isComplete && keyAnalyzer) {
        uint64_t phaseStart = VibeLoadClockNow();
        result.key = [keyAnalyzer finish];
        nanos.keyFinish = VibeLoadClockNow() - phaseStart;
    }
    nanos.total = VibeLoadClockNow() - loadStart;
#if DEBUG
    [AudioLoadTiming recordPath:filename
                   audioSeconds:(NSTimeInterval)totalFrames / file.processingFormat.sampleRate
                     bpmEnabled:bpmAnalyzer != nil
                     keyEnabled:keyAnalyzer != nil
                          nanos:nanos];
#endif
    return result;
}

@end
