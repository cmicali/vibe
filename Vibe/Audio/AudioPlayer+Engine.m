//
//  AudioPlayer+Engine.m
//  Vibe
//

#import "AudioPlayer+Engine.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"

// Give the next track time to open before releasing the idle engine.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 6.0;

// Starting the engine and starting the node both run on the player queue, so
// either one blocking delays every transport action queued behind it — a seek
// included, which is how a slow device shows up as a slow SEEK (#53). On a
// healthy device both are tens of milliseconds; a device that accepts the bind
// and is slow to deliver its first IO cycle can hold [node play] for seconds.
//
// Logged at WARN rather than DEBUG so it PERSISTS: a user hitting this can
// retrieve it afterwards with `log show`, instead of having to catch it live
// with `log stream` while the app is frozen.
//
// One second, not a tighter bound, because normal operation is not free:
// measured on healthy hardware, the engine start alone is ~0.22s and the node
// play ~0.007s, and a bit-perfect device switch reached 0.73s. A threshold
// under that would warn about working correctly, which is how an instrument
// stops being read.
static const NSTimeInterval kSlowEngineStartLogThresholdSeconds = 0.25;

static NSTimeInterval VibeSecondsSince(uint64_t startNanos) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanos) / NSEC_PER_SEC;
}

#if VIBE_VERBOSE_LOGGING
// Beta instrumentation (#47): the offset of the first frame at or above
// -60 dBFS within the first three seconds of url, so a track that opens with
// silence is not read as a late start. -1 when unreadable or silent throughout.
static double VibeSecondsToFirstSound(NSURL *url) {
    AVAudioFile *file = url ? [[AVAudioFile alloc] initForReading:url error:NULL] : nil;
    AVAudioFormat *format = file.processingFormat;
    AVAudioFrameCount frames = (AVAudioFrameCount)MIN(file.length, (AVAudioFramePosition)(format.sampleRate * 3));
    AVAudioPCMBuffer *buffer = file && frames > 0
            ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames] : nil;
    if (!buffer || ![file readIntoBuffer:buffer frameCount:frames error:NULL] || !buffer.floatChannelData) {
        return -1;
    }
    for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) {
        for (AVAudioChannelCount c = 0; c < format.channelCount; c++) {
            if (fabsf(buffer.floatChannelData[c][i]) >= 0.001f) {
                return i / format.sampleRate;
            }
        }
    }
    return -1;
}
#endif

@implementation AudioPlayer (Engine)

// TRAP: [AVAudioPlayerNode play] throws if the engine stopped between the
// isRunning check and the call, and the engine stops itself on device and
// format changes. Start it if needed, and absorb the race.
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
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
            [self logFirstRenderOfNode:node playedAt:playedAt];
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
// Beta instrumentation (#47): when the node's first frame actually reached the
// output, read from the node's own render clock rather than assumed from
// [node play] returning — the reporter's time counter stays still through the
// lag, and it counts rendered frames. For a track start, also how long after
// the request. Manual rendering has no hardware clock to measure, so the
// render suites skip it.
- (void)logFirstRenderOfNode:(AVAudioPlayerNode *)node playedAt:(uint64_t)playedAt {
    os_unfair_lock_lock(&_stateLock);
    uint64_t requestedAt = _timelineRequestedAt;
    _timelineRequestedAt = 0;
    os_unfair_lock_unlock(&_stateLock);
    if (_engine.isInManualRenderingMode) {
        return;
    }
    if (requestedAt && playedAt - requestedAt > 30 * NSEC_PER_SEC) {
        requestedAt = 0; // a request that never started, not this one
    }
    [self pollFirstRenderOfNode:node playedAt:playedAt requestedAt:requestedAt
                        latency:_engine.outputNode.presentationLatency attempt:0];
}

// TRAP: poll on _queue, never off it. This queue detaches nodes, and AVFAudio
// raises (required condition _engine != nil) when a node's render time is read
// while it is being detached; off the queue that was a crash the first time a
// crossfade retired the node mid-poll. A node no longer attached was
// superseded, which ends the poll without a line.
- (void)pollFirstRenderOfNode:(AVAudioPlayerNode *)node playedAt:(uint64_t)playedAt
                  requestedAt:(uint64_t)requestedAt latency:(double)latency attempt:(int)attempt {
    if (node.engine != _engine) {
        return;
    }
    AVAudioTime *render = nil;
    AVAudioTime *player = nil;
    @try {
        render = node.lastRenderTime;
        if (render.sampleTimeValid && render.hostTimeValid) {
            player = [node playerTimeForNodeTime:render];
        }
    }
    @catch (NSException *exception) {
        return; // instrumentation must never take playback down with it
    }
    if (!(player.sampleTimeValid && player.sampleTime > 0)) {
        if (attempt >= 1500) {
            LogWarn(@"Timeline: no audio rendered 3 s after node play");
            return;
        }
        __weak AudioPlayer *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), _queue, ^{
            [weakSelf pollFirstRenderOfNode:node playedAt:playedAt requestedAt:requestedAt
                                    latency:latency attempt:attempt + 1];
        });
        return;
    }
    // The host time of the node's frame 0: the render's host time, minus the
    // frames the node has rendered since.
    double firstOut = [AVAudioTime secondsForHostTime:render.hostTime] - player.sampleTime / player.sampleRate;
    NSURL *url = requestedAt ? self.currentTrack.url : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableString *line = [NSMutableString stringWithFormat:
                @"Timeline: first audio out %.0f ms after node play", (firstOut - playedAt / 1e9) * 1000];
        if (requestedAt) {
            double request = requestedAt / 1e9;
            [line appendFormat:@", %.0f ms after the play was requested", (firstOut - request) * 1000];
            double sound = VibeSecondsToFirstSound(url);
            if (sound >= 0) {
                [line appendFormat:@"; %@ opens with %.0f ms of near-silence, so sound at the output %.0f ms "
                        @"after the request", url.lastPathComponent, sound * 1000,
                        (firstOut + sound - request) * 1000];
            }
        }
        [line appendFormat:@"; output presentation latency %.1f ms", latency * 1000];
        LogInfo(@"%@", line);
    });
}
#endif

- (void)scheduleEngineIdleStopOnQueue {
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
