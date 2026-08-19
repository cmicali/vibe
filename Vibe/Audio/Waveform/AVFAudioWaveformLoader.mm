//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//
// One decode of one file, in five phases — the five methods below, in the
// order load: calls them: open and validate, size the chunk array, run the
// pipelined decode, settle what "complete" means, and stretch a short file
// across the full width. Only the third is long, and it is one thing: a
// two-slot producer/consumer loop whose halves must not be read apart.
//

#import "AVFAudioWaveformLoaderInternal.h"
#import "AudioWaveform.h"
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
#import "AudioLoadTiming.h"
#import "NSURL+AudioOpen.h"
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

    struct VibeWaveformDecodePass pass = {};
    AVAudioFile *file = [self openFileAtPath:filename pass:&pass];
    if (!file) {
        return nil;
    }

    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    CodableAudioWaveform *result = [self makeWaveformForPass:&pass
                                                    waveform:&waveform
                                                   numChunks:&numChunks];
    if (!result) {
        return nil;
    }

    // Tempo and key detection ride the same decode pass: each analyzer
    // consumes the buffer right after the waveform chunk does, so neither
    // costs a second full-file read, which matters for cloud-backed files.
    // With one off there is no analyzer, and the waveform caches with no BPM
    // or key — a file scanned while off is not re-analyzed on re-enable until
    // its cache entry goes. The explicit scan_bpm and scan_key debug paths run
    // the analyzers directly and ignore this.
    //
    // The answer is asked of the provider rather than read from the settings,
    // so this layer stays testable and iOS — which never analyzes — installs
    // nothing. No provider means neither runs.
    VibeWaveformAnalysis analysis = self.analysisProvider ? self.analysisProvider()
                                                          : (VibeWaveformAnalysis){NO, NO};
    AudioBPMAnalyzer *bpmAnalyzer = analysis.bpm
            ? [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate]
            : nil;
    AudioKeyAnalyzer *keyAnalyzer = analysis.key
            ? [[AudioKeyAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate]
            : nil;

    if (![self runDecodePass:&pass
                        file:file
                    filename:filename
                    waveform:waveform
                      result:result
                 bpmAnalyzer:bpmAnalyzer
                 keyAnalyzer:keyAnalyzer
                       nanos:&nanos]) {
        // Cancelled mid-decode, so the data really is partial. A cancel that
        // lands after the loop has read every chunk falls through instead: the
        // decode is complete and worth caching for the next play of this
        // track. The cache's delivery site filters cancelled loads out of the
        // UI, so discarding here would only lose that cache write. (The buffer
        // allocation failing answers NO too — there is nothing to show.)
        return nil;
    }

    self.isComplete = [self isDecodeComplete:&pass filename:filename];

    [self stretchWaveform:waveform pass:&pass numChunks:numChunks];

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
                   audioSeconds:(NSTimeInterval)pass.totalFrames / file.processingFormat.sampleRate
                     bpmEnabled:bpmAnalyzer != nil
                     keyEnabled:keyAnalyzer != nil
                          nanos:nanos];
#endif
    return result;
}

#pragma mark - Phase 1: open and validate

// Opens the file for reading and fills in the shape half of the pass. nil for
// a file that cannot be opened, holds no audio, or whose open blocked long
// enough for a cancel to arrive.
- (AVAudioFile *)openFileAtPath:(NSString *)filename pass:(struct VibeWaveformDecodePass *)pass {
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (url.isEmptyOrDirectory) {
        // Opening it would leak a descriptor; see NSURL+AudioOpen.
        LogError(@"AVAudioFile open skipped for empty path %@", filename);
        return nil;
    }
    // Interleaved float32, because AudioWaveformMonoMix expects the sample
    // layout L0 R0 L1 R1 and so on.
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url
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

    pass->totalFrames = file.length;
    pass->numChannels = file.processingFormat.channelCount;
    if (pass->totalFrames <= 0 || pass->numChannels == 0) {
        LogError(@"AVAudioFile reports no audio in %@ (frames=%lld channels=%lu)",
                 filename, pass->totalFrames, (unsigned long)pass->numChannels);
        return nil;
    }
    return file;
}

#pragma mark - Phase 2: size the chunk array

// Mints the waveform and settles how many of its chunks this file can fill.
// The out-parameters are the raw waveform, which the chunker writes through,
// and its full chunk count, which the stretch pass needs.
- (CodableAudioWaveform *)makeWaveformForPass:(struct VibeWaveformDecodePass *)pass
                                     waveform:(AudioWaveform **)outWaveform
                                    numChunks:(NSUInteger *)outNumChunks {
    AudioWaveform *waveform = new AudioWaveform();
    // Wrap it immediately so that ARC manages the lifetime. The decode pass's
    // blocks capture the result strongly, keeping the waveform alive until
    // every pending callback has fired.
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
    pass->effectiveChunks = pass->totalFrames < (AVAudioFramePosition)numChunks
            ? (NSUInteger)pass->totalFrames
            : numChunks;

    *outWaveform = waveform;
    *outNumChunks = numChunks;
    return result;
}

#pragma mark - Phase 3: the pipelined decode

// Reads the file in large blocks, downmixes each to mono once, and feeds that
// mono block to the chunker and both analyzers on a serial queue one block
// behind the decode. NO when the pass has nothing worth keeping — a cancel
// that landed while chunks were still missing, or buffers that would not
// allocate. A read failure answers YES with the error in pass->readError;
// isDecodeComplete: still fails the pass, so the partial result is never
// delivered or persisted — only the progressive snapshots already shown
// survive, and they survive a NO the same way.
- (BOOL)runDecodePass:(struct VibeWaveformDecodePass *)pass
                 file:(AVAudioFile *)file
             filename:(NSString *)filename
             waveform:(AudioWaveform *)waveform
               result:(CodableAudioWaveform *)result
          bpmAnalyzer:(AudioBPMAnalyzer *)bpmAnalyzer
          keyAnalyzer:(AudioKeyAnalyzer *)keyAnalyzer
                nanos:(VibeLoadPhaseNanos *)nanos {

    const AVAudioFramePosition totalFrames = pass->totalFrames;
    const NSUInteger numChannels = pass->numChannels;
    const NSUInteger effectiveChunks = pass->effectiveChunks;

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
        return NO;
    }

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
    // the decode loop writes only nanos->read.
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
    NSError *error = nil;

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
        nanos->read += VibeLoadClockNow() - phaseStart;
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
            // separately. A detached decode still persists its final result,
            // but its UI-only snapshot copies and main-queue blocks are waste.
            if (!self.isCancelled && !self.isDetached) {
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
                    if (!self.isCancelled && !self.isDetached) {
                        dispatch_async(dispatch_get_main_queue(), ^(void) {
                            if (!self.isCancelled && !self.isDetached) {
                                [self.delegate audioWaveformLoader:self waveform:snapshot didLoadData:percentComplete];
                            }
                        });
                    }
                }
            }
            dispatch_semaphore_signal(slotDone);
        });
        slot ^= 1;
    }
    // Drain the pipeline. After this the processing state above is safe to
    // read and the pass is single-threaded again.
    dispatch_sync(processQueue, ^{});
    nanos->chunk = procNanos.chunk;
    nanos->bpmAppend = procNanos.bpmAppend;
    nanos->keyAppend = procNanos.keyAppend;

    // EOF with a partly accumulated chunk: keep it.
    if (currentChunkHasFrames && chunkIndex < effectiveChunks) {
        waveform->setChunkAtIndex(currentChunk, chunkIndex);
        chunksFilled = chunkIndex + 1;
    }

    pass->chunksFilled = chunksFilled;
    pass->framesRead = framesRead;
    pass->readError = readError;

    return !(self.isCancelled && chunksFilled < effectiveChunks);
}

#pragma mark - Phase 4: what counts as complete

// Whether the decode covered enough of the file to cache and to analyze.
// It also promotes an early EOF to a read error, which is why it is not a
// pure predicate: with exact lengths, EOF lands only right at the end.
- (BOOL)isDecodeComplete:(struct VibeWaveformDecodePass *)pass filename:(NSString *)filename {
    if (!pass->readError && !self.isCancelled
            && pass->framesRead < pass->totalFrames
            && pass->chunksFilled + 2 < pass->effectiveChunks) {
        // Ending more than about two chunks early means truncation.
        LogError(@"Audio ended early at chunk %lu of %lu in %@",
                 (unsigned long)pass->chunksFilled, (unsigned long)pass->effectiveChunks, filename);
        pass->readError = YES;
    }

    // Match the EOF tolerance above: a read ending up to two chunks short of
    // file.length's claim counts as complete, because a VBR mis-tag or slight
    // truncation over-reports the length. A threshold stricter than the EOF
    // tolerance would leave such files neither errored nor complete — frozen
    // mid-load, never cached, and nothing logged. effectiveChunks is at least
    // 1; guard the unsigned subtraction for tiny files.
    NSUInteger completeThreshold = pass->effectiveChunks > 2 ? pass->effectiveChunks - 2 : 1;
    BOOL complete = !pass->readError && pass->chunksFilled >= completeThreshold;
    if (complete && pass->chunksFilled < pass->effectiveChunks) {
        LogWarn(@"Waveform for %@ decoded short: %lu of %lu chunks (file length over-reported)",
                filename, (unsigned long)pass->chunksFilled, (unsigned long)pass->effectiveChunks);
    }
    return complete;
}

#pragma mark - Phase 5: stretch a short file

// For a file with fewer frames than chunks, stretch the decoded chunks across
// the full chunk array, back to front so it is safe in place, so that the
// waveform spans the full view width rather than leaving a silent tail. A
// no-op for every ordinary file, which fills the array outright.
- (void)stretchWaveform:(AudioWaveform *)waveform
                   pass:(struct VibeWaveformDecodePass *)pass
              numChunks:(NSUInteger)numChunks {
    if (!(self.isComplete && pass->effectiveChunks < numChunks && pass->chunksFilled > 0)) {
        return;
    }
    NSUInteger chunksFilled = pass->chunksFilled;
    for (NSInteger i = (NSInteger)numChunks - 1; i >= 0; i--) {
        NSUInteger src = (NSUInteger)i * chunksFilled / numChunks;
        waveform->setChunkAtIndex(waveform->getChunkAtIndex(src, numChunks), (NSUInteger)i);
    }
}

@end
