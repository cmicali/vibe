//
//  AudioPlayer+Engine.m
//  Vibe
//

#import "AudioPlayer+Engine.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"

// Give the next track time to open before releasing the idle engine.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 6.0;

// Both calls hold the player queue. Log their costs separately: a slow
// engine start and a node waiting for its first IO cycle need different fixes.
// Warnings persist even when beta logging is disabled.
static const NSTimeInterval kSlowEngineStartLogThresholdSeconds = 0.25;

static NSTimeInterval VibeSecondsSince(uint64_t startNanos) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanos) / NSEC_PER_SEC;
}

@implementation AudioPlayer (Engine)

- (uint64_t)diagnosticPlayIdentifierOnQueue {
    return _state == VibePlayerStateLoading ? self.loadingSubmittedPlayIdentifier : _activeSubmittedPlayIdentifier;
}

- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID
                     operation:(BOOL (^)(void))operation {
#if VIBE_VERBOSE_LOGGING
    uint64_t play = [self diagnosticPlayIdentifierOnQueue], segment = _segmentGeneration;
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Phase: play %llu segment %llu %@ begin, target %ld, state %ld",
            play, segment, phase, (long)deviceID, (long)_state);
#endif
    BOOL success = operation();
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Phase: play %llu segment %llu %@ end, target %ld, success %d, %.1f ms",
            play, segment, phase, (long)deviceID, success, VibeSecondsSince(began) * 1000);
#endif
    return success;
}

- (void)beginOutputSignalDiagnosticsOnQueue:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    AudioLevelTap *tap = _levelTap;
    uint64_t request = [tap beginSignalDiagnostics];
    uint64_t play = [self diagnosticPlayIdentifierOnQueue], segment = _segmentGeneration;
    LogInfo(@"Signal: play %llu segment %llu %@, %@ (post-mix observation, not audible output)",
            play, segment, reason, request ? @"three-second capture armed" : @"unavailable: no active level tap");
    if (!request) return;
    [self scheduleAfterSeconds:3.05 block:^{
        NSDictionary *snapshot = [tap signalDiagnosticSnapshot];
        if (snapshot[@"request"] && [snapshot[@"request"] unsignedLongLongValue] != request) {
            LogInfo(@"Signal: play %llu segment %llu capture superseded", play, segment);
            return;
        }
        LogInfo(@"Signal: play %llu segment %llu capture %@", play, segment, snapshot);
    }];
#endif
}

// TRAP: [AVAudioPlayerNode play] throws if the engine stopped between the
// isRunning check and the call, and the engine stops itself on device and
// format changes. Start it if needed, and absorb the race.
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    if (_terminating) return NO;
    _engineIdleStopGeneration++; // playback is starting: cancel any pending idle stop
    NSTimeInterval engineStartSeconds = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!_engine.isRunning) {
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
            [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
                [self acquireExclusiveOutputOnQueue];
                return YES; // ownership confirmation is logged by the nested hog phase
            }];
#endif
            __block NSError *startError = nil;
            uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            BOOL started = [self performDiagnosticPhase:@"engine start" device:-1 operation:^BOOL{
                return [self->_engine startAndReturnError:&startError];
            }];
            engineStartSeconds += VibeSecondsSince(startedAt);
            if (!started) {
                if (outError) {
                    *outError = startError;
                }
                return NO;
            }
        }
        // A tap request made against a not-yet-runnable graph can observe a
        // temporarily unusable output format and return nil. Playback start is
        // the next meaningful lifecycle edge, so retry here without requiring
        // the UI to toggle demand off and on.
        [self applyLevelTapOnQueue];
        @try {
#if DEBUG
            // TRAP: offline rendering can outrun the node's asynchronous file read.
            if (_engine.isInManualRenderingMode) {
                [node prepareWithFrameCount:_engine.manualRenderingMaximumFrameCount];
            }
#endif
#if VIBE_VERBOSE_LOGGING
            AVAudioFramePosition initialSample = 0;
            if (_state == VibePlayerStatePaused && node == _node && _file.processingFormat.sampleRate > 0) {
                initialSample = MAX(0, llround(self.pausedRawPosition * _file.processingFormat.sampleRate) - _segmentStartFrame);
            }
            @try {
                AVAudioTime *render = _engine.isInManualRenderingMode ? nil : node.lastRenderTime;
                AVAudioTime *before = render && (render.sampleTimeValid || render.hostTimeValid)
                        ? [node playerTimeForNodeTime:render] : nil;
                if (before.sampleTimeValid) initialSample = before.sampleTime;
            } @catch (NSException *exception) {}
#endif
            uint64_t playedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [self performDiagnosticPhase:@"node play" device:-1 operation:^BOOL{
                [node play];
                return YES;
            }];
            NSTimeInterval nodePlaySeconds = VibeSecondsSince(playedAt);
            // Attribute the stall to the call that actually held the queue:
            // engine start and node play fail for different reasons, and the
            // remedy differs, so a single total would not separate them.
            BOOL slowStart =
                    engineStartSeconds + nodePlaySeconds > kSlowEngineStartLogThresholdSeconds;
            LogTiming(slowStart, @"AudioPlayer: %@start — engine %.3fs, node play %.3fs "
                    @"(the player queue was blocked for this long)",
                    slowStart ? @"slow " : @"", engineStartSeconds, nodePlaySeconds);
#if VIBE_VERBOSE_LOGGING
            [self logFirstRenderOfNode:node playedAt:playedAt initialSample:initialSample];
#endif
            [self beginOutputSignalDiagnosticsOnQueue:@"node started"];
            [self refreshOutputAudioActiveOnQueue];
            return YES;
        }
        @catch (NSException *exception) {
            LogError(@"AudioPlayer: node play threw (%@); retrying", exception.reason);
        }
    }
    return NO;
}

#if VIBE_VERBOSE_LOGGING
// The node clock proves render progress, not when a DAC produces sound.
// Defer once so a new play has published its track and submission identity.
- (void)logFirstRenderOfNode:(AVAudioPlayerNode *)node playedAt:(uint64_t)playedAt
               initialSample:(AVAudioFramePosition)initialSample {
    if (_engine.isInManualRenderingMode) return;
    uint64_t generation = _segmentGeneration;
    __weak AudioPlayer *weakSelf = self;
    dispatch_async(_queue, ^{
        AudioPlayer *player = weakSelf;
        if (!player || generation != player->_segmentGeneration || node != player->_node) return;
        [player pollFirstRenderOfNode:node playedAt:playedAt initialSample:initialSample
                            generation:generation submittedPlay:player->_activeSubmittedPlayIdentifier];
    });
}

// TRAP: poll on _queue, never off it. Reading the clock during a detach raises.
// A seek can reuse the node, so attachment alone cannot fence an old poll.
- (void)pollFirstRenderOfNode:(AVAudioPlayerNode *)node playedAt:(uint64_t)playedAt
               initialSample:(AVAudioFramePosition)initialSample generation:(uint64_t)generation
               submittedPlay:(uint64_t)submittedPlay {
    if (generation != _segmentGeneration || node != _node || node.engine != _engine
            || _state != VibePlayerStatePlaying || !node.isPlaying) return;
    AVAudioTime *render = nil, *player = nil;
    @try {
        render = node.lastRenderTime;
        if (render.sampleTimeValid) player = [node playerTimeForNodeTime:render];
    }
    @catch (NSException *exception) {
        LogWarn(@"Timeline: play %llu segment %llu render clock unavailable: %@", submittedPlay, generation, exception.reason);
        return;
    }
    double elapsed = VibeSecondsSince(playedAt);
    if (player.sampleTimeValid && player.sampleTime > initialSample) {
        NSString *estimate = @"unavailable (resumed clock, host clock or non-unity playback rate)";
        if (initialSample == 0 && render.hostTimeValid && player.sampleRate > 0
                && (!self.varispeed || self.varispeed.rate == 1)) {
            // A resumed clock has no exact frame-zero origin for this start.
            double firstRender = [AVAudioTime secondsForHostTime:render.hostTime]
                    - player.sampleTime / player.sampleRate;
            estimate = [NSString stringWithFormat:@"%.1f ms after node play", (firstRender - playedAt / 1e9) * 1000];
        }
        LogInfo(@"Timeline: play %llu segment %llu %@ estimated first render %@; first observed render progress %.1f ms after node play; "
                @"sample %lld (baseline %lld), rate %.0f Hz, reported output presentation latency %.1f ms (not measured audible output)",
                submittedPlay, generation, self.currentTrack.url.lastPathComponent, estimate, elapsed * 1000,
                player.sampleTime, initialSample, player.sampleRate, _engine.outputNode.presentationLatency * 1000);
        return;
    }
    if (elapsed >= 3) {
        LogWarn(@"Timeline: play %llu segment %llu %@ no render progress after %.0f ms, state %ld, engine %d",
                submittedPlay, generation, self.currentTrack.url.lastPathComponent, elapsed * 1000,
                (long)_state, _engine.isRunning);
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), _queue, ^{
        [weakSelf pollFirstRenderOfNode:node playedAt:playedAt initialSample:initialSample
                            generation:generation submittedPlay:submittedPlay];
    });
}
#endif

// TRAP: engine stop fires segment completions, including when no replacement
// output exists. Retire first, then retain a resumable schedule at the intent.
- (void)stopEnginePreservingTrackOnQueue {
    VibePendingPlaybackIntent intent;
    BOOL loaded = [self getPlaybackIntent:&intent forTrack:self.currentTrack]
            && (_state == VibePlayerStatePlaying || _state == VibePlayerStatePaused)
            && _node && _file;
    BOOL settlesPause = loaded && intent.paused && _state == VibePlayerStatePlaying;
    _segmentGeneration++;
    _seekRampGeneration = [self preemptRampsOnQueue];
    [self setGaplessQueuedOnQueue:NO];
    [_node stop];
    [_engine stop];
    if (loaded) {
        AVAudioFramePosition start = VibeClampedStartFrame(intent.position, _file.processingFormat.sampleRate, _file.length);
        _pendingSeekPosition = -1;
        [self scheduleFile:_file onNode:_node fromFrame:start];
        [self publishPlaybackState:intent.paused ? VibePlayerStatePaused : VibePlayerStatePlaying
                              node:_node file:_file segmentStart:start position:intent.position];
    }
    [self refreshOutputAudioActiveOnQueue];
    if (settlesPause) {
        AudioTrack *track = self.currentTrack;
        run_on_main_thread({ [self.delegate audioPlayer:self didPausePlaying:track]; });
    }
}

- (void)scheduleEngineIdleStopOnQueue {
    if (_terminating) return;
    uint64_t generation = ++_engineIdleStopGeneration;
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:kEngineIdleStopDelaySeconds block:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_engineIdleStopGeneration) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_stateLock);
        VibePlayerState state = strongSelf->_state;
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        // Only a still-idle player stops the engine. Loading counts as busy,
        // because the in-flight open's finish path wants a warm engine.
        if (state == VibePlayerStateStopped) {
            [strongSelf->_engine stop];
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
            [strongSelf releaseExclusiveOutputOnQueue];
#endif
        }
        else if (state == VibePlayerStatePaused && strongSelf->_node && strongSelf->_file) {
            [strongSelf stopEnginePreservingTrackOnQueue];
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
            [strongSelf releaseExclusiveOutputOnQueue];
#endif
            [strongSelf maybeArmGaplessOnQueue];
        }
    }];
}

@end
