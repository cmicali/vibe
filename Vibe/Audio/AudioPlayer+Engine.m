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
            [self acquireExclusiveOutputOnQueue]; // gates itself on both settings
#endif
            NSError *startError = nil;
            uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            BOOL started = [_engine startAndReturnError:&startError];
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
            @try {
                AVAudioTime *render = node.lastRenderTime;
                AVAudioTime *before = render ? [node playerTimeForNodeTime:render] : nil;
                if (before.sampleTimeValid) initialSample = before.sampleTime;
            } @catch (NSException *exception) {}
#endif
            uint64_t playedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [node play];
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
    AVAudioTime *player = nil;
    @try {
        AVAudioTime *render = node.lastRenderTime;
        if (render.sampleTimeValid) player = [node playerTimeForNodeTime:render];
    }
    @catch (NSException *exception) {
        LogWarn(@"Timeline: play %llu segment %llu render clock unavailable: %@", submittedPlay, generation, exception.reason);
        return;
    }
    double elapsed = VibeSecondsSince(playedAt);
    if (player.sampleTimeValid && player.sampleTime > initialSample) {
        LogInfo(@"Timeline: play %llu segment %llu %@ first observed render progress %.1f ms after node play; "
                @"sample %lld, rate %.0f Hz, reported output presentation latency %.1f ms (not measured audible output)",
                submittedPlay, generation, self.currentTrack.url.lastPathComponent, elapsed * 1000,
                player.sampleTime, player.sampleRate, _engine.outputNode.presentationLatency * 1000);
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
            // TRAP: the paused node still carries its scheduled segment, and
            // pause deliberately leaves _segmentGeneration current — so the
            // stops below would fire that segment's completion as a natural
            // track end and auto-advance out of a pause (observed, not
            // hypothetical). Retire it, silence the node, stop the engine and
            // reschedule in place from the paused frame, exactly the paused
            // seek's ballet: scheduling needs no running engine, and the
            // resume's startEngineAndPlayNode: plays the fresh segment.
            NSTimeInterval position = strongSelf.position; // Paused: the published value
            strongSelf->_segmentGeneration++;
            [strongSelf setGaplessQueuedOnQueue:NO]; // the stop below drops the queued segment
            AVAudioPlayerNode *node = strongSelf->_node;
            AVAudioFile *file = strongSelf->_file;
            [node stop];
            [strongSelf->_engine stop];
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
            [strongSelf releaseExclusiveOutputOnQueue];
#endif
            double sampleRate = file.processingFormat.sampleRate;
            AVAudioFramePosition startFrame = VibeClampedStartFrame(position, sampleRate, file.length);
            [strongSelf scheduleFile:file onNode:node fromFrame:startFrame];
            [strongSelf publishPlaybackState:VibePlayerStatePaused node:node file:file
                                segmentStart:startFrame position:position];
            [strongSelf maybeArmGaplessOnQueue];
        }
    }];
}

@end
