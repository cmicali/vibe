//
//  AudioWaveformLoader.mm
//  Vibe
//
// One decode of one file, in four phases — the methods below, in the order
// decode: calls them: open and validate, start the summary, run the
// pipelined decode, and settle what "complete" means. Only the third is long,
// and it is one thing: a two-slot producer/consumer loop whose halves must
// not be read apart.
//

#import "AudioWaveformLoaderInternal.h"
#import "AudioWaveform.h"
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
#import "AudioLoadTiming.h"
#import "CloudFileMaterializer.h"
#import "CueWindowMath.h"
#if DEBUG
#import "AudioWaveformCache+Debug.h"
#endif
#import <AVFAudio/AVFAudio.h>

#include <array>
#include <atomic>
#include <memory>
#include <vector>

@implementation AudioWaveformLoader {
    // What cancel interrupts, under @synchronized (self): the file the open
    // asked for, and the handle from its return until the load ends.
    NSURL *_url;
    AudioFileHandle *_file;
}

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate {
    self = [super init];
    if (self) {
        self.isCancelled = NO;
        self.isComplete = NO;
        self.delegate = delegate;
    }
    return self;
}

- (void)cancel {
    // Always set isCancelled — even after completion — so a completed-but-
    // undelivered waveform for a previous track is dropped at delivery time.
    NSURL *url;
    AudioFileHandle *file;
    @synchronized (self) {
        self.isCancelled = YES;
        url = _url;
        file = _file;
    }
    // A streaming file's wait for bytes ends here, so its decode slot frees
    // now rather than when the download gets there: the open's through its
    // interrupted block, a read's through the handle.
    [file interruptReads];
    if (url) {
        [[CloudFileMaterializer availabilityForURL:url] wakeWaiters];
    }
}

- (void)detach {
    self.isDetached = YES;
}

- (void)reattach {
    self.isDetached = NO;
}

- (CodableAudioWaveform *)load:(NSString *)filename {
    CodableAudioWaveform *result = [self decode:filename];
    // TRAP: the claim and its wait timer can outlive the load. Release the
    // handle here or each retained loader also retains an open descriptor.
    @synchronized (self) {
        _file = nil;
    }
    return result;
}

- (BOOL)loadDetailBlocks:(NSIndexSet *)blocks ofFile:(NSString *)filename
            intoWaveform:(CodableAudioWaveform *)waveform {
    AudioWaveform *summary = waveform.waveform;
    if (!summary || self.isCancelled) {
        return NO;
    }
    struct VibeWaveformDecodePass pass = {};
    AudioFileHandle *file = [self openFileAtPath:filename pass:&pass];
    const AVAudioFrameCount blockFrames = (AVAudioFrameCount)wavecore::Detail::kBlockFrames;
    AVAudioPCMBuffer *buffer = file ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                  frameCapacity:blockFrames] : nil;
    BOOL ok = buffer != nil;
    for (NSUInteger block = blocks.firstIndex; ok && block != NSNotFound; block = [blocks indexGreaterThanIndex:block]) {
        AVAudioFramePosition start = (AVAudioFramePosition)block * blockFrames;
        if (summary->detail().hasBlock((int64_t)block) || start >= pass.totalFrames) {
            continue;
        }
        NSError *error = nil;
        AVAudioFrameCount count = (AVAudioFrameCount)MIN((AVAudioFramePosition)blockFrames, pass.totalFrames - start);
        ok = !self.isCancelled && [file seekToFrame:pass.windowStart + start error:&error]
                && [file readIntoBuffer:buffer frameCount:count error:&error];
        if (ok) {
            // Mixed straight into the block the detail keeps.
            std::vector<float> samples(buffer.frameLength);
            const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], samples.data(),
                                                     buffer.frameLength, pass.numChannels);
            if (mono != samples.data()) {
                std::copy_n(mono, buffer.frameLength, samples.data());
            }
            summary->detail().insertBlock((int64_t)block, std::move(samples));
        } else if (error && ![AudioFileHandle isInterruption:error]) {
            LogError(@"Detail read failed at frame %lld of %@: %@", start, filename, error);
        }
    }
    // As load: does, so a loader kept past its read keeps no descriptor.
    @synchronized (self) {
        _file = nil;
    }
    return ok;
}

- (CodableAudioWaveform *)decode:(NSString *)filename {

    // Phase timings for this pass. The clock reads compile to constants in
    // Release, where nothing consumes them; see AudioLoadTiming.h.
    VibeLoadPhaseNanos nanos = {};
    uint64_t loadStart = VibeLoadClockNow();

    // A cancel may have arrived while this load was queued, so honor it.
    if (self.isCancelled) {
        return nil;
    }

    struct VibeWaveformDecodePass pass = {};
    AudioFileHandle *file = [self openFileAtPath:filename pass:&pass];
    if (!file) {
        return nil;
    }
    BOOL sizedByEstimate = file.lengthIsEstimated;
    std::unique_ptr<wavecore::SummaryBuilder> builder;
    AudioBPMAnalyzer *bpmAnalyzer = nil;
    AudioKeyAnalyzer *keyAnalyzer = nil;
    for (;;) {
        if (!builder) {
            builder = [self builderForPass:&pass sampleRate:file.processingFormat.sampleRate];
            // Tempo and key detection share the waveform's mono buffers.
            // Neither needs a second read of the track window.
            // With one off there is no analyzer, and the entry is filed
            // without that analysis (bpmAnalyzed, keyAnalyzed). A later
            // request that runs it misses on the entry and decodes again. The
            // explicit scan_bpm and scan_key debug paths run the analyzers
            // directly and ignore this.
            VibeWaveformAnalysis analysis = self.analysis;
            bpmAnalyzer = analysis.bpm ? [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate] : nil;
            keyAnalyzer = analysis.key ? [[AudioKeyAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate] : nil;
        }

        if (![self runDecodePass:&pass
                            file:file
                        filename:filename
                         builder:builder.get()
                     bpmAnalyzer:bpmAnalyzer
                     keyAnalyzer:keyAnalyzer
                           nanos:&nanos]) {
            // Cancelled mid-decode, so the data really is partial. A cancel
            // that lands after the loop has read every frame falls through
            // instead: the decode is complete and worth caching for the next
            // play of this track. The cache's delivery site filters cancelled
            // loads out of the UI, so discarding here would only lose that
            // cache write. (The buffer allocation failing answers NO too —
            // there is nothing to show.)
            return nil;
        }
        if (!sizedByEstimate || pass.readError) {
            break;
        }
        // TRAP: a pass sized by an estimated length (a streaming MP3's with
        // no VBR header) would be filed under the file's key, so it is
        // complete only once the length is exact. A bin's frames never depend
        // on the length, so the pass keeps everything it read: it goes on
        // reading to the exact length, or stops where the file did. Only a
        // cue window that moved with the length starts over.
        NSError *error = nil;
        if (![file awaitExactLength:&error]) {
            if (![AudioFileHandle isInterruption:error]) {
                VibeLogAt(self.isDetached ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
                          @"No exact length for %@: %@", filename, error);
            }
            return nil;
        }
        sizedByEstimate = NO;
        NSRange window = [self windowOfFile:file];
        if ((AVAudioFramePosition)window.location != pass.windowStart) {
            AVAudioFramePosition sized = pass.totalFrames;
            pass = {};
            builder = nullptr;
            if (![self sizePass:&pass forFile:file filename:filename]) {
                return nil;
            }
            LogInfo(@"Waveform window for %@ moved once its length of %lld frames was exact (sized by %lld); decoding it again",
                    filename, pass.totalFrames, sized);
            continue;
        }
        pass.totalFrames = (AVAudioFramePosition)window.length;
        builder->setExpectedFrames(pass.totalFrames);
        if (pass.framesRead >= pass.totalFrames || pass.reachedEnd) {
            break;
        }
    }

    self.isComplete = [self isDecodeComplete:&pass filename:filename];
    CodableAudioWaveform *result = [[CodableAudioWaveform alloc] initWithWaveform:builder->finish(self.isComplete)];

    if (self.isComplete && bpmAnalyzer) {
        uint64_t phaseStart = VibeLoadClockNow();
        result.bpmAnalyzed = YES;
        result.bpm = [bpmAnalyzer finish];
        nanos.bpmFinish = VibeLoadClockNow() - phaseStart;
    }
    if (self.isComplete && keyAnalyzer) {
        uint64_t phaseStart = VibeLoadClockNow();
        result.keyAnalyzed = YES;
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
- (AudioFileHandle *)openFileAtPath:(NSString *)filename pass:(struct VibeWaveformDecodePass *)pass {
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:filename];
    @synchronized (self) {
        _url = url;
    }
    // Interleaved float32, because AudioWaveformMonoMix expects the sample
    // layout L0 R0 L1 R1 and so on. A streaming file's handle never holds
    // its transfer (holdStream): the play's do, and when they let it go the
    // reads fail with it.
    __weak AudioWaveformLoader *weakSelf = self;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url interleaved:YES interrupted:^BOOL{
        AudioWaveformLoader *loader = weakSelf;
        return !loader || loader.isCancelled;
    } error:&error];
    if (!file) {
        if (![AudioFileHandle isInterruption:error]) {
            LogError(@"Audio open failed for %@: %@", filename, error);
        }
        return nil;
    }
    BOOL cancelled;
    @synchronized (self) {
        _file = file;
        cancelled = self.isCancelled;
    }
    if (cancelled) {
        // The open blocked, on a cloud placeholder or a slow mount, and the
        // track changed meanwhile. Skip the decode setup entirely.
        return nil;
    }
    return [self sizePass:pass forFile:file filename:filename] ? file : nil;
}

// The row's window of the file, on its length as it stands.
- (NSRange)windowOfFile:(AudioFileHandle *)file {
    BOOL estimated = NO;
    AVAudioFramePosition length = [file lengthEstimated:&estimated];
    return VibeCueWindow(self.cueStart, self.cueEnd, file.processingFormat.sampleRate, length, estimated);
}

// The shape half of the pass, from the window, with the file's cursor at the
// window's start. NO for no audio or a refused seek.
- (BOOL)sizePass:(struct VibeWaveformDecodePass *)pass forFile:(AudioFileHandle *)file filename:(NSString *)filename {
    NSRange window = [self windowOfFile:file];
    pass->windowStart = (AVAudioFramePosition)window.location;
    pass->totalFrames = (AVAudioFramePosition)window.length;
    pass->numChannels = file.processingFormat.channelCount;
    if (pass->totalFrames <= 0 || pass->numChannels == 0) {
        LogError(@"No audio in %@ (frames=%lld channels=%lu)",
                 filename, pass->totalFrames, (unsigned long)pass->numChannels);
        return NO;
    }
    NSError *error = nil;
    if ((window.location > 0 || file.framePosition != 0)
            && ![file seekToFrame:(AVAudioFramePosition)window.location error:&error]) {
        LogError(@"Seek to the window of %@ failed: %@", filename, error);
        return NO;
    }
    return YES;
}

#pragma mark - Phase 2: start the summary

// The summary the decode fills, laid out on the window's length as it stands.
// Its bins sit on a grid of frames from the window's start, so a length that
// changes later moves none of them.
- (std::unique_ptr<wavecore::SummaryBuilder>)builderForPass:(struct VibeWaveformDecodePass *)pass
                                                 sampleRate:(double)sampleRate {
    return std::make_unique<wavecore::SummaryBuilder>(self.analysis.bands, pass->totalFrames, sampleRate);
}

#pragma mark - Phase 3: the pipelined decode

// Reads the file in large blocks, downmixes each to mono once, and feeds the
// block to the summary, which splits the bands from the mono, and the mono to
// both analyzers, on a serial queue one block behind the decode. It continues
// from pass->framesRead, so a pass sized by an estimate can read on to the
// exact length. NO when the pass has nothing worth keeping — a cancel that
// landed while frames were still missing, or buffers that would not allocate.
// A read failure answers YES with the error in pass->readError;
// isDecodeComplete: still fails the pass, so the partial result is never
// delivered or persisted — only the progressive snapshots already shown
// survive, and they survive a NO the same way.
- (BOOL)runDecodePass:(struct VibeWaveformDecodePass *)pass
                 file:(AudioFileHandle *)file
             filename:(NSString *)filename
              builder:(wavecore::SummaryBuilder *)builder
          bpmAnalyzer:(AudioBPMAnalyzer *)bpmAnalyzer
          keyAnalyzer:(AudioKeyAnalyzer *)keyAnalyzer
                nanos:(VibeLoadPhaseNanos *)nanos {

    const AVAudioFramePosition totalFrames = pass->totalFrames;
    const NSUInteger numChannels = pass->numChannels;

    // Large reads amortize decoder-call overhead. Bins are sliced in memory.
    // Block N+1 decodes here as block N runs through the serial processing
    // queue. Reuse waits for the slot's semaphore to protect its buffer. The
    // serial queue preserves the stream order required by the analyzers.
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
    // Each decode buffer is downmixed once and fed to both the summary and
    // the analyzers. Mono files skip the mix entirely, since
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
    // A local decode accumulates a full interval before its first snapshot.
    // A file whose reads wait for bytes, a stream or a read-ahead, publishes
    // its first block before its next read can stall.
    __block CFAbsoluteTime lastProgressTime = file.waitsForBytes ? 0 : CFAbsoluteTimeGetCurrent();
    __block AVAudioFramePosition framesProcessed = pass->framesRead;
    // A snapshot on its way to main. While one is, no newer one is made: a
    // main thread that stalled was handed a queue of them, about 1 MB each,
    // and refilled and retargeted its view for every one already superseded.
    auto snapshotWaiting = std::make_shared<std::atomic<bool>>(false);

    dispatch_semaphore_t slotFree[2] = { dispatch_semaphore_create(1), dispatch_semaphore_create(1) };
    int slot = 0;
    BOOL readError = NO;
    BOOL reachedEnd = NO;
    AVAudioFramePosition framesRead = pass->framesRead;
    NSError *error = nil;
#if DEBUG
    const NSTimeInterval debugDecodeSeconds = AudioWaveformCache.debugDecodeSeconds;
    const CFAbsoluteTime debugDecodeStart = CFAbsoluteTimeGetCurrent();
#endif

    while (framesRead < totalFrames && !self.isCancelled) {
        // Wait for this slot's previous processing to finish before reusing
        // its buffer. With two slots the decode runs at most one block ahead.
        dispatch_semaphore_wait(slotFree[slot], DISPATCH_TIME_FOREVER);
        AVAudioPCMBuffer *buffer = buffers[slot];
        float *scratch = monoScratches[slot].data();

        AVAudioFrameCount toRead = (AVAudioFrameCount)MIN(
                (AVAudioFramePosition)kReadBlockFrames, totalFrames - framesRead);
        // A sequential read: the handle advances its framePosition.
        uint64_t phaseStart = VibeLoadClockNow();
        BOOL readOK = [file readIntoBuffer:buffer frameCount:toRead error:&error];
        nanos->read += VibeLoadClockNow() - phaseStart;
        if (!readOK) {
            // An interruption is cancel's own. A detached load's stream
            // failing is the play letting it go, not a fault of this file.
            if (![AudioFileHandle isInterruption:error]) {
                VibeLogAt(self.isDetached ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
                          @"Read failed at frame %lld of %lld in %@: %@", framesRead, totalFrames, filename, error);
            }
            readError = YES;
            dispatch_semaphore_signal(slotFree[slot]);
            break;
        }
        if (buffer.frameLength == 0) {
            // EOF; the completeness thresholds below decide what it means.
            reachedEnd = YES;
            dispatch_semaphore_signal(slotFree[slot]);
            break;
        }
        NSUInteger numFrames = buffer.frameLength;
        framesRead += numFrames;
#if DEBUG
        // Held to its share of the debug pace, in short sleeps so a cancel
        // still ends the pass promptly.
        CFAbsoluteTime due = debugDecodeStart + debugDecodeSeconds * (double)framesRead / (double)totalFrames;
        while (!self.isCancelled && CFAbsoluteTimeGetCurrent() < due) {
            [NSThread sleepForTimeInterval:MIN(0.02, due - CFAbsoluteTimeGetCurrent())];
        }
#endif

        dispatch_semaphore_t slotDone = slotFree[slot];
        dispatch_async(processQueue, ^{
            // The downmix counts as baseline: the summary needs it whether or
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

            // The summary slices the block into its bins, and splits the
            // bands from the mono when it keeps them.
            procStart = VibeLoadClockNow();
            builder->append(mono, numFrames);
            procNanos.chunk += VibeLoadClockNow() - procStart;
            framesProcessed += numFrames;

            // Throttle delegate notifications to about 10 Hz, because each one
            // refills the view's target and redraws its picture on main.
            // AudioWaveformCache delivers the final completion callback
            // separately. A detached decode still persists its final result,
            // but its UI-only snapshot copies and main-queue blocks are waste.
            if (!self.isCancelled && !self.isDetached) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastProgressTime >= 0.1 && !snapshotWaiting->load()) {
                    lastProgressTime = now;
                    // Short of 1 with every frame read: 1 is the completion's,
                    // which AudioWaveformCache delivers, and a pass sized by an
                    // estimate reads its length before the length is exact.
                    float percentComplete = MIN((float)framesProcessed / (float)MAX(totalFrames, 1),
                                                nextafterf(1, 0));
                    // Snapshot on this queue, the only writer, so that the
                    // main thread renders an immutable copy. Reading the live
                    // summary would be a data race, because this queue keeps
                    // appending to it.
                    CodableAudioWaveform *snapshot = [[CodableAudioWaveform alloc] initWithWaveform:builder->snapshot()];
                    if (!self.isCancelled && !self.isDetached) {
                        snapshotWaiting->store(true);
                        run_on_main_thread({
                            snapshotWaiting->store(false);
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
    nanos->chunk += procNanos.chunk;
    nanos->bpmAppend += procNanos.bpmAppend;
    nanos->keyAppend += procNanos.keyAppend;

    pass->framesRead = framesRead;
    pass->readError = readError;
    pass->reachedEnd = reachedEnd;

    return !(self.isCancelled && framesRead < totalFrames);
}

#pragma mark - Phase 4: what counts as complete

+ (AVAudioFramePosition)shortfallToleranceForFrames:(AVAudioFramePosition)totalFrames {
    return MAX((AVAudioFramePosition)2, totalFrames / 4096);
}

// Whether the decode covered enough of the file to cache and to analyze.
// It also promotes an early EOF to a read error, which is why it is not a
// pure predicate. Small length discrepancies stay within the tolerance.
- (BOOL)isDecodeComplete:(struct VibeWaveformDecodePass *)pass filename:(NSString *)filename {
    AVAudioFramePosition tolerance = [AudioWaveformLoader shortfallToleranceForFrames:pass->totalFrames];
    if (!pass->readError && !self.isCancelled
            && pass->framesRead + tolerance < pass->totalFrames) {
        // Ending more than the tolerance early means truncation.
        LogError(@"Audio ended early at frame %lld of %lld in %@",
                 pass->framesRead, pass->totalFrames, filename);
        pass->readError = YES;
    }

    // Match the EOF tolerance above: a read ending within it of
    // file.length's claim counts as complete, because a VBR mis-tag or slight
    // truncation over-reports the length. A threshold stricter than the EOF
    // tolerance would leave such files neither errored nor complete — frozen
    // mid-load, never cached, and nothing logged.
    BOOL complete = !pass->readError && pass->framesRead > 0
            && pass->framesRead + tolerance >= pass->totalFrames;
    if (complete && pass->framesRead < pass->totalFrames) {
        LogWarn(@"Waveform for %@ decoded short: %lld of %lld frames (file length over-reported)",
                filename, pass->framesRead, pass->totalFrames);
    }
    return complete;
}

@end
