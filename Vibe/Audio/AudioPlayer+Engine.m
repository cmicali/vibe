//
//  AudioPlayer+Engine.m
//  Vibe
//

#import "AudioPlayer+Engine.h"
#import "AudioPlayerInternal.h"

// How long the engine may sit idle before it is stopped to release the output
// device. Long enough to absorb even a slow next-track open, short enough to
// let go promptly when playback really ends; see the header for why it is
// deferred at all. Shorter while the device is hogged for bit-perfect output,
// because until the stop nothing else on the Mac can use it.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 10.0;
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
static const NSTimeInterval kEngineIdleStopDelayHoggedSeconds = 6.0;
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
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!_engine.isRunning) {
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
            [self acquireExclusiveOutputOnQueue]; // bit-perfect: hog rides the running engine
#endif
            NSError *startError = nil;
            if (![_engine startAndReturnError:&startError]) {
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
            [node play];
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
    NSTimeInterval delay = kEngineIdleStopDelaySeconds;
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
    if (_hoggedDeviceID != kAudioObjectUnknown) {
        delay = kEngineIdleStopDelayHoggedSeconds;
    }
#endif
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
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
    });
}

@end
