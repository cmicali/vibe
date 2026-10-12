//
//  AudioPlayer+Diagnostics.m
//  Vibe
//

#import "AudioPlayer+Diagnostics.h"
#import "AudioPlayerInternal.h"
#import "AudioFileFormat.h"
#import "AudioTrack.h"
#import "AudioFX.h"
#include <mach/mach_time.h>
#if DEBUG
#import "VibeManualRenderPump.h"
#endif

#if VIBE_VERBOSE_LOGGING
#import <pthread.h>
#import "StallWatch.h"

static NSTimeInterval VibeMillisecondsSince(uint64_t nanos) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - nanos) / 1e6;
}
#endif

@implementation AudioPlayer (Diagnostics)

#pragma mark - The path

static NSString *VibeCodecName(AudioFormatID format) {
    VibeAudioFileFormat named = VibeAudioFileFormatForCodec(format);
    if (named) {
        return named;
    }
    switch (format) {
        case kAudioFormatLinearPCM:     return @"PCM";
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2: return @"HE-AAC";
        case kAudioFormatMPEGLayer1:    return @"MP1";
        default: {
            char text[5] = { (char)(format >> 24), (char)(format >> 16), (char)(format >> 8), (char)format, 0 };
            return [NSString stringWithFormat:@"%s", text];
        }
    }
}

static NSString *VibeSampleFormatName(AVAudioFormat *format) {
    switch (format.commonFormat) {
        case AVAudioPCMFormatInt16:   return @"int16";
        case AVAudioPCMFormatInt32:   return @"int32";
        case AVAudioPCMFormatFloat32: return @"float32";
        case AVAudioPCMFormatFloat64: return @"float64";
        default:                      return @"other";
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)audioPathOnQueue {
    NSArray *outputUnitPath = [self outputUnitAudioPathOnQueue];
    NSDictionary *renderFacts = [self pipelineRenderSnapshotOnQueue];
    AudioFileHandle *file = _file;
    NSMutableDictionary *source = [@{@"stage": @"source", @"present": @(file != nil)} mutableCopy];
    if (file) {
        const AudioStreamBasicDescription *asbd = file.fileFormat.streamDescription;
        source[@"file"] = file.url.lastPathComponent ?: @"";
        source[@"codec"] = VibeCodecName(asbd->mFormatID);
        source[@"lossless"] = @(asbd->mFormatID == kAudioFormatLinearPCM || asbd->mFormatID == kAudioFormatFLAC
                                || asbd->mFormatID == kAudioFormatAppleLossless);
        source[@"sampleRate"] = @(file.fileFormat.sampleRate);
        source[@"channels"] = @(file.fileFormat.channelCount);
        // Only PCM's flags say float: a lossless codec's flags are its source
        // depth, and the 24-bit one carries the float bit.
#if TARGET_OS_OSX
        source[@"bitsPerChannel"] = @(VibeSourceBitDepth(*asbd));
        source[@"float"] = @(VibeSourceIsFloat(*asbd));
#else
        source[@"bitsPerChannel"] = @(asbd->mBitsPerChannel);
        source[@"float"] = @(asbd->mFormatID == kAudioFormatLinearPCM && (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0);
#endif
        source[@"frames"] = @(file.length);
        source[@"decodedSampleFormat"] = VibeSampleFormatName(file.processingFormat);
        source[@"decoder"] = file.decoderName;
    }

    NSDictionary *conversion = [_voiceBus conversionOfVoice:_voice];
    AVAudioFormat *decodedFormat = _voice ? file.processingFormat : nil;
    NSMutableDictionary *decode = [@{@"stage": @"decode", @"present": @(_voice != 0 && decodedFormat != nil)} mutableCopy];
    if (decodedFormat) {
        decode[@"sampleFormat"] = VibeSampleFormatName(decodedFormat);
        decode[@"sampleRate"] = @(decodedFormat.sampleRate);
        decode[@"channels"] = @(decodedFormat.channelCount);
    }
    decode[@"read"] = conversion ? @"converted" : @"direct";
    [decode addEntriesFromDictionary:conversion ?: @{}];

    AudioVoiceBus *bus = _voiceBus;
    VibeVoiceSnapshot snapshot = [bus snapshotOfVoice:_voice];
    NSDictionary *busStage = @{
        @"stage": @"bus", @"present": @(bus != nil),
        @"sampleRate": @((bus.format ?: _masterFormat).sampleRate),
        @"channels": @((bus.format ?: _masterFormat).channelCount),
        @"sampleFormat": @"float32",
        @"liveVoices": @(bus.liveVoiceCount), @"occupiedSlots": @(bus.occupiedSlotCount),
        @"currentVoice": @(_voice), @"gain": @(snapshot.gain), @"consumedFrames": @(snapshot.consumed),
        @"underrunFrames": @(snapshot.underrunFrames), @"inlineDecoding": @(bus.inlineDecoding),
    };

    NSDictionary *varispeedStage = renderFacts[@"varispeed"];

    NSMutableDictionary *fx = [@{
        @"stage": @"fx", @"present": @YES, @"enabled": @(_fxEnabled), @"wanted": @([self fxWantedOnQueue]),
        @"inRender": renderFacts[@"fxInRender"],
    } mutableCopy];
    [fx addEntriesFromDictionary:self.fx.diagnosticSnapshot ?: @{}];

    NSDictionary *meter = @{
        @"stage": @"meter", @"present": @(_levelMeter != nil), @"installed": @(_levelMeter.installed),
        @"inRender": renderFacts[@"meterInRender"],
        @"wanted": @(_levelsWanted), @"probe": @(self.signalProbeWanted),
        @"sampleRate": @(_levelMeter.sampleRate), @"normalizationMode": @(_levelNormalizationMode),
    };

    NSMutableDictionary *output = [@{
        @"stage": @"output", @"present": @YES,
        @"sampleRate": @(_masterFormat.sampleRate), @"channels": @(_masterFormat.channelCount), @"sampleFormat": @"float32",
        @"running": @([self renderingOnQueue]),
        // Running with nothing to play: the deferred idle stop is pending.
        @"idleStopPending": @([self renderingOnQueue] && (_state == VibePlayerStateStopped || _state == VibePlayerStatePaused)),
        @"idle": @(self.outputIdle),
        @"silent": renderFacts[@"silent"],
        @"framesRendered": renderFacts[@"framesRendered"],
    } mutableCopy];
#if DEBUG
    VibeManualRenderPump *pump = _manualPump;
    if (pump) {
        output[@"renderedBy"] = @"pump";
        output[@"automatic"] = @(pump.automatic);
    }
    else
#endif
    {
        output[@"renderedBy"] = @"outputUnit";
        if (_outputUnit) {
            output[@"unitSampleRate"] = @(_outputUnit.format.sampleRate);
            output[@"unitRunning"] = @(_outputUnit.running);
            [output addEntriesFromDictionary:[self outputUnitCountersOnQueue]];
            output[@"presentationLatency"] = @(_outputUnit.presentationLatency);
            output[@"bufferLatency"] = @(_outputUnit.bufferLatency); // the IO cycle the unit fills ahead of the hardware
        }
        [output addEntriesFromDictionary:outputUnitPath.firstObject];
    }

    NSMutableArray *stages = [NSMutableArray arrayWithObjects:source, decode, busStage, varispeedStage, fx, meter, output, nil];
    if (outputUnitPath.count > 1) [stages addObjectsFromArray:[outputUnitPath subarrayWithRange:NSMakeRange(1, outputUnitPath.count - 1)]];

    return stages;
}


- (void)startStallWatchers {
#if VIBE_VERBOSE_LOGGING
    // The main thread is one per process, so its watcher is too; its port is
    // read on the main thread itself, where the production player is made,
    // since there is no public way to name the main thread from another.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VibeWatchMainThreadForStalls(NSThread.isMainThread ? pthread_mach_thread_np(pthread_self()) : MACH_PORT_NULL);
    });
    // The player queue runs on whichever pool thread is free; the watcher
    // finds the one draining it at each sample.
    _queueStallWatcher = VibeWatchQueueForStalls(_queue, @"player queue");
#endif
}

// The queue watcher ticks while the player has work that can stall — the
// output running, or a device phase in flight on a stopped output (a bind, a
// format write, the idle stop's hog release) — and is suspended otherwise,
// so an idle player wakes nothing. Balanced: one resume per suspend.
- (void)refreshQueueStallWatcherOnQueue {
#if VIBE_VERBOSE_LOGGING
    BOOL wanted = [self renderingOnQueue] || _diagnosticPhaseDepth > 0;
    if (!_queueStallWatcher || wanted == _queueStallWatcherRunning) {
        return;
    }
    _queueStallWatcherRunning = wanted;
    if (wanted) {
        dispatch_resume(_queueStallWatcher);
    }
    else {
        dispatch_suspend(_queueStallWatcher);
    }
#endif
}

- (void)noteOutputEdgeOnQueue {
#if VIBE_VERBOSE_LOGGING
    if (![self renderingOnQueue]) {
        // No drain follows a stop to close a stall the last one opened.
        if (_renderClockStalledSince) {
            LogWarn(@"Stall: output render clock stalled %.0f ms, then the output stopped (play %llu, %@)",
                    (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _renderClockStalledSince) / 1e6,
                    [self diagnosticPlayIdentifierOnQueue], self.currentTrack.url.lastPathComponent);
        }
        _renderClockStalledSince = 0;
        _renderClockAdvancedAt = 0;
    }
    [self refreshQueueStallWatcherOnQueue];
#endif
}

- (uint64_t)diagnosticPlayIdentifierOnQueue {
    return _state == VibePlayerStateLoading ? self.loadingSubmittedPlayIdentifier : _activeSubmittedPlayIdentifier;
}

- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID operation:(BOOL (^)(void))operation {
#if VIBE_VERBOSE_LOGGING
    uint64_t play = [self diagnosticPlayIdentifierOnQueue];
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Phase: play %llu voice %llu %@ begin, target %ld, state %ld", play, _voice, phase, (long)deviceID, (long)_state);
    _diagnosticPhaseDepth++; // HAL work on a stopped output: the queue watcher runs for it
    [self refreshQueueStallWatcherOnQueue];
#endif
    BOOL success = operation();
#if VIBE_VERBOSE_LOGGING
    _diagnosticPhaseDepth--;
    [self refreshQueueStallWatcherOnQueue];
    LogInfo(@"Phase: play %llu voice %llu %@ end, target %ld, success %d, %.1f ms",
            play, _voice, phase, (long)deviceID, success, VibeMillisecondsSince(began));
#endif
    return success;
}

#pragma mark - Timeline

- (uint64_t)noteSubmittedPlay:(uint64_t)submittedPlay track:(AudioTrack *)track position:(NSTimeInterval)position paused:(BOOL)paused {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu submitted %@ at %.3fs, paused %d", submittedPlay, track.url.lastPathComponent, position, paused);
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

- (uint64_t)noteSubmittedAction:(NSString *)action position:(NSTimeInterval)position {
#if VIBE_VERBOSE_LOGGING
    uint64_t submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: %@ submitted at %llu%@", action, submittedAt,
            position >= 0 ? [NSString stringWithFormat:@" to %.3fs", position] : @"");
    return submittedAt;
#else
    return 0;
#endif
}

- (void)noteAdmittedPlay:(uint64_t)submittedPlay submittedAt:(uint64_t)submittedAt {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu admitted after %.1f ms on player queue", submittedPlay, VibeMillisecondsSince(submittedAt));
#endif
}

- (void)noteAdmittedAction:(NSString *)action submittedAt:(uint64_t)submittedAt position:(NSTimeInterval)position {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ %llu admitted after %.1f ms%@, state %ld",
            [self diagnosticPlayIdentifierOnQueue], _voice, action, submittedAt, VibeMillisecondsSince(submittedAt),
            position >= 0 ? [NSString stringWithFormat:@", target %.3fs", position] : @"", (long)_state);
#endif
}

- (void)noteOpenSettledForPlay:(uint64_t)submittedPlay track:(AudioTrack *)track file:(AudioFileHandle *)file error:(NSError *)error {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu open settled for %@, %.0f Hz, %lld frames, error %@",
            submittedPlay, track.url.lastPathComponent, file.processingFormat.sampleRate, file.length, error);
#endif
}

- (void)noteVoiceStarted:(VibeVoiceID)voice file:(AudioFileHandle *)file fromFrame:(AVAudioFramePosition)frame reason:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ %@ from %lld of %lld frames at %.0f Hz",
            [self diagnosticPlayIdentifierOnQueue], voice, reason, file.url.lastPathComponent, frame, file.length,
            file.processingFormat.sampleRate);
    _firstRenderVoice = voice;
#endif
}

#if VIBE_VERBOSE_LOGGING
// The device's load, for a glitch line: a hot or throttled phone is slower to
// decode and render. Any thread.
static NSString *VibeLoadNote(void) {
    NSProcessInfo *process = NSProcessInfo.processInfo;
    return [NSString stringWithFormat:@"thermal %ld, low power %d",
            (long)process.thermalState, process.lowPowerModeEnabled];
}

// The three glitches shorter than a stall, each logged at the drain after it:
// a callback that outran its buffer, a device clock that skipped ahead of the
// render, and a current voice whose ring ran dry. A count below the last one
// was cleared by a measurement.
- (void)noteGlitchesOnQueue:(BOOL)playing {
    uint64_t late = _outputUnit.lateCycles, jumps = _outputUnit.clockJumps, skipped = _outputUnit.skippedFrames;
    double rate = [self masterBusFormatOnQueue].sampleRate;
    if (playing && late > _renderClockLateCycles) {
        LogWarn(@"Stall: %llu render callbacks ran longer than their audio, %.1f ms buffer, max %.0f µs, mean %.0f µs (play %llu, %@; %@)",
                late - _renderClockLateCycles, _outputUnit.bufferLatency * 1000, _outputUnit.renderMaxMicroseconds,
                _outputUnit.renderMeanMicroseconds, [self diagnosticPlayIdentifierOnQueue],
                self.currentTrack.url.lastPathComponent, VibeLoadNote());
    }
    if (playing && jumps > _renderClockJumps) {
        uint64_t frames = skipped > _renderClockSkippedFrames ? skipped - _renderClockSkippedFrames : 0;
        LogWarn(@"Stall: output clock jumped %llu times, skipping %llu frames (%.1f ms) it never asked the render for, max render %.0f µs (play %llu, %@; %@)",
                jumps - _renderClockJumps, frames, rate > 0 ? frames * 1000.0 / rate : 0,
                _outputUnit.renderMaxMicroseconds, [self diagnosticPlayIdentifierOnQueue],
                self.currentTrack.url.lastPathComponent, VibeLoadNote());
    }
    _renderClockLateCycles = late;
    _renderClockJumps = jumps;
    _renderClockSkippedFrames = skipped;
    if (!playing || !_voice) {
        return;
    }
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:_voice];
    if (_voice != _underrunVoice) {
        _underrunVoice = _voice;
        _underrunFrames = 0;
    }
    if (snapshot.underrunFrames > _underrunFrames && rate > 0) {
        uint64_t frames = snapshot.underrunFrames - _underrunFrames;
        uint64_t buffered = snapshot.written > snapshot.consumed ? snapshot.written - snapshot.consumed : 0;
        LogWarn(@"Stall: voice %llu underran %llu frames (%.1f ms) %.3fs in, %.0f ms buffered, decoding %d, waiting for bytes %d (play %llu, %@; %@)",
                _voice, frames, frames * 1000.0 / rate, snapshot.consumed / rate, buffered * 1000.0 / rate,
                snapshot.decoding, snapshot.waitingForBytes, [self diagnosticPlayIdentifierOnQueue],
                self.currentTrack.url.lastPathComponent, VibeLoadNote());
    }
    _underrunFrames = snapshot.underrunFrames;
}
#endif

// Read at every drain, so it needs no wakeup of its own. A stopped clock means
// the device's IO stopped pulling. noteOutputEdgeOnQueue closes a stall a stop
// cuts short.
- (void)noteRenderClockOnQueue {
#if VIBE_VERBOSE_LOGGING
    if (![self drivesOutputDeviceOnQueue]) {
        return;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL playing = _state == VibePlayerStatePlaying;
    // The other stall: the device keeps pulling, the pipeline cannot render.
    // A count below the last one was cleared by a measurement, not a stall.
    uint64_t dropouts = _outputUnit.dropouts;
    if (playing && dropouts > _renderClockDropouts) {
        LogWarn(@"Stall: output unit wrote silence for %llu IO cycles the pipeline could not render (play %llu, %@)",
                dropouts - _renderClockDropouts, [self diagnosticPlayIdentifierOnQueue],
                self.currentTrack.url.lastPathComponent);
    }
    _renderClockDropouts = dropouts;
    [self noteGlitchesOnQueue:playing];
    uint64_t frames = [self renderedFramesOnQueue];
    if (!playing || frames != _renderClockFrames) {
        if (_renderClockStalledSince) {
            LogWarn(@"Stall: output render clock resumed/stopped after %.0f ms (play %llu, %@)",
                    (now - _renderClockStalledSince) / 1e6, [self diagnosticPlayIdentifierOnQueue],
                    self.currentTrack.url.lastPathComponent);
        }
        _renderClockFrames = frames;
        _renderClockAdvancedAt = playing ? now : 0;
        _renderClockStalledSince = 0;
        return;
    }
    if (!_renderClockAdvancedAt) {
        _renderClockAdvancedAt = now;
    }
    if (!_renderClockStalledSince && now - _renderClockAdvancedAt > 200 * NSEC_PER_MSEC) {
        _renderClockStalledSince = _renderClockAdvancedAt;
        LogWarn(@"Stall: output render clock stalled %.0f ms (play %llu, %@)", (now - _renderClockStalledSince) / 1e6,
                [self diagnosticPlayIdentifierOnQueue], self.currentTrack.url.lastPathComponent);
        // Stuck in our render, or waiting for a device that stopped asking:
        // the IO thread's stack tells the two apart. RemoteIO names its own.
#if TARGET_OS_OSX
        thread_t io = VibeFindThread(nil, "com.apple.audio.IOThread.client");
#else
        thread_t io = VibeFindThread(nil, "AURemoteIO::IOThread");
#endif
        if (io == MACH_PORT_NULL) {
            LogWarn(@"Stall stack: no audio IO thread exists");
        }
        else {
            VibeSampleStack(io, @"audio IO thread", (now - _renderClockStalledSince) / 1e6, nil);
            mach_port_deallocate(mach_task_self(), io);
        }
    }
#endif
}

// The live event often precedes the voice's first render, so the first-render
// line waits for the drain that first sees its stamp.
- (void)noteDrainOnQueue {
#if VIBE_VERBOSE_LOGGING
    [self noteRenderClockOnQueue];
    VibeVoiceID voice = _firstRenderVoice;
    if (!voice || voice != _voice) {
        return;
    }
    AudioTimeStamp start = [_voiceBus snapshotOfVoice:voice].startOfConsumption;
    if (!(start.mFlags & (kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid))) {
        return; // not yet rendered
    }
    _firstRenderVoice = 0;
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    // Signed: a render's host time is when its buffer is heard, which can
    // still be ahead of now.
    double ticksAgo = (double)mach_absolute_time() - (double)start.mHostTime;
    NSString *when = (start.mFlags & kAudioTimeStampHostTimeValid)
            ? [NSString stringWithFormat:@"host time %llu (%.1f ms ago)", start.mHostTime,
               ticksAgo * timebase.numer / timebase.denom / 1e6]
            : [NSString stringWithFormat:@"sample time %.0f", start.mSampleTime];
    NSTimeInterval latency = _outputUnit.presentationLatency;
    LogInfo(@"Timeline: play %llu voice %llu %@ live; first render at %@; reported output presentation latency %.1f ms (not measured audible output)",
            [self diagnosticPlayIdentifierOnQueue], voice, self.currentTrack.url.lastPathComponent, when, latency * 1000);
#endif
}

- (void)noteBusEvent:(VibeVoiceEvent)event voice:(VibeVoiceID)voice current:(BOOL)current {
#if VIBE_VERBOSE_LOGGING
    NSString *name = event == VibeVoiceEventLive ? @"live" : event == VibeVoiceEventBoundary ? @"boundary" : @"ended";
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:voice];
    LogInfo(@"Callback: play %llu voice %llu %@, %@, consumed %llu, underrun %llu frames, state %ld",
            [self diagnosticPlayIdentifierOnQueue], voice, name, current ? @"current" : @"retiring",
            snapshot.consumed, snapshot.underrunFrames, (long)_state);
    if (event == VibeVoiceEventLive && voice == _firstRenderVoice && current) {
        [self noteDrainOnQueue];
    }
    if (snapshot.underrunFrames && event == VibeVoiceEventEnded) {
        LogWarn(@"Stall: voice %llu underran %llu frames over its life", voice, snapshot.underrunFrames);
    }
#endif
}

- (void)noteSettled:(NSString *)what reason:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ settled: %@", [self diagnosticPlayIdentifierOnQueue], _voice, what, reason);
#endif
}

- (uint64_t)deliveryStamp {
#if VIBE_VERBOSE_LOGGING
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

- (void)noteDelivery:(NSString *)what forPlay:(uint64_t)submittedPlay accepted:(BOOL)accepted deliveredAt:(uint64_t)deliveredAt {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu %@ main delivery %.1f ms, %@", submittedPlay, what, VibeMillisecondsSince(deliveredAt),
            accepted ? @"accepted" : @"dropped: newer play");
#endif
}

#pragma mark - The signal probe

- (BOOL)signalProbeWanted {
    return _signalProbeWanted;
}

#if VIBE_VERBOSE_LOGGING
// Drops the probe's hold on the meter once the newest capture has completed; the
// indicator's own demand, if any, keeps the meter installed.
- (void)releaseSignalProbeOnQueue:(uint64_t)request {
    if (request != _signalProbeRequest || !_signalProbeWanted) {
        return;
    }
    _signalProbeWanted = NO;
    [self applyLevelMeterOnQueue];
}

- (void)pollOutputSignalDiagnosticsOnQueue:(AudioLevelMeter *)meter request:(uint64_t)request {
    [self scheduleAfterSeconds:0.1 block:^{
        if ([meter pollSignalDiagnostics:request]) {
            [self pollOutputSignalDiagnosticsOnQueue:meter request:request];
        }
    }];
}
#endif

- (void)armSignalProbeOnQueue:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    // The indicator may be hidden, and a meter installed late misses the
    // opening: on hardware the probe holds the meter itself.
    if ([self drivesOutputDeviceOnQueue] && !_signalProbeWanted) {
        _signalProbeWanted = YES;
        [self applyLevelMeterOnQueue];
    }
    AudioLevelMeter *meter = _levelMeter;
    uint64_t play = [self diagnosticPlayIdentifierOnQueue], voice = _voice;
    NSString *track = self.currentTrack.url.lastPathComponent;
    __block uint64_t request = 0;
    __weak AudioPlayer *weakSelf = self;
    request = [meter beginSignalDiagnosticsAtTime:[self outputRenderTimeOnQueue]
                         waitingForRetiredAudio:_retiringVoices.count > 0
                                     completion:^(NSDictionary *snapshot) {
        if (!([snapshot[@"completion"] isEqual:@"superseded"] && [snapshot[@"status"] isEqual:@"no buffers observed"])) {
            LogInfo(@"Signal: play %llu voice %llu %@ %@ capture %@", play, voice, track, reason, snapshot);
        }
        // Not from inside the meter's own call: releasing the demand may remove it.
        AudioPlayer *player = weakSelf;
        if (player) dispatch_async(player->_queue, ^{ [player releaseSignalProbeOnQueue:request]; });
    }];
    if (!request) {
        LogInfo(@"Signal: play %llu voice %llu %@ %@ unavailable: no active level meter (post-mix observation, not audible output)",
                play, voice, track, reason);
    }
    if (request) [self pollOutputSignalDiagnosticsOnQueue:meter request:request];
    _signalProbeRequest = request;
    if (!request) [self releaseSignalProbeOnQueue:0];
#endif
}

// TRAP: the varispeed emits the bus's frames late by its kernel's half-width:
// 64 input frames, and ceil(64 × ratio) above a ratio of 1, which play in
// half / ratio output frames. So the cutoff is padded by
// varispeedLatencyOnQueue, which is 0 at zero pitch, where the converter is
// skipped. Unpadded, the probe reads the outgoing track's tail as the
// incoming one's first signal.
- (void)noteRetiringAudioSilentOnQueue {
#if VIBE_VERBOSE_LOGGING
    AudioTimeStamp time = [self outputRenderTimeOnQueue];
    NSTimeInterval latency = [self varispeedLatencyOnQueue];
    if ((time.mFlags & kAudioTimeStampSampleTimeValid) && latency > 0) {
        time.mSampleTime += ceil(latency * _masterFormat.sampleRate);
    }
    [_levelMeter endSignalOverlapAtTime:time];
#endif
}

#pragma mark - The first displayed position

- (void)notePublishedPlayingPosition:(NSTimeInterval)position track:(AudioTrack *)track voice:(VibeVoiceID)voice {
#if VIBE_VERBOSE_LOGGING
    NSDictionary *diagnostic = track ? @{
        @"track": track, @"play": @([self diagnosticPlayIdentifierOnQueue]), @"voice": @(voice),
        @"position": @(position), @"publishedAt": @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) } : nil;
    os_unfair_lock_lock(&_stateLock);
    _positionDiagnostic = diagnostic;
    os_unfair_lock_unlock(&_stateLock);
#endif
}

- (void)recordDisplayedPosition:(NSTimeInterval)position forTrack:(AudioTrack *)track {
#if VIBE_VERBOSE_LOGGING
    os_unfair_lock_lock(&_stateLock);
    NSDictionary *diagnostic = _positionDiagnostic;
    BOOL matches = track && diagnostic[@"track"] == track
            && [diagnostic[@"play"] unsignedLongLongValue] == _nextSubmittedPlayIdentifier
            && position > [diagnostic[@"position"] doubleValue];
    if (matches) _positionDiagnostic = nil;
    os_unfair_lock_unlock(&_stateLock);
    if (matches) {
        LogInfo(@"Timeline: play %@ voice %@ first advancing UI position %.3fs (published %.3fs), %.1f ms after state publication",
                diagnostic[@"play"], diagnostic[@"voice"], position, [diagnostic[@"position"] doubleValue],
                VibeMillisecondsSince([diagnostic[@"publishedAt"] unsignedLongLongValue]));
    }
#endif
}

@end
