//
//  AudioPlayer+Engine.m
//  Vibe
//

#import "AudioPlayer+Engine.h"
#import "AudioPlayerInternal.h"

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
            // Always logged, not only when slow: a report of "nothing appeared"
            // must mean the path was not taken, never that it was fast.
            LogWarn(@"AudioPlayer: %@start — engine %.3fs, node play %.3fs "
                    @"(the player queue was blocked for this long)",
                    engineStartSeconds + nodePlaySeconds > kSlowEngineStartLogThresholdSeconds
                            ? @"slow " : @"",
                    engineStartSeconds, nodePlaySeconds);
            [self refreshOutputAudioActiveOnQueue];
            return YES;
        }
        @catch (NSException *exception) {
            LogError(@"AudioPlayer: node play threw (%@); retrying", exception.reason);
        }
    }
    return NO;
}

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
