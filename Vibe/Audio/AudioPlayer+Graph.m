//
//  AudioPlayer+Graph.m
//  Vibe
//

#import "AudioPlayer+Graph.h"
#import "AudioPlayerInternal.h"
#import "AudioScheduleMath.h"

@implementation AudioPlayer (Graph)

// Wires node -> varispeed -> mixer for a track's format. Each track gets a
// fresh varispeed, connected exactly once here, so it never reinitializes
// across a channel-count change. TRAP: a varispeed reconnected between stereo
// and mono throws kAudioUnitErr_FormatNotSupported and forces an engine stop.
// The one re-connect, in device-switch recovery, rewires the same varispeed
// for the same format with the engine stopped, which is safe; the catch clause
// backstops whatever formats the graph still refuses. The rate does not affect
// position math — playerTimeForNodeTime: counts the file frames the player
// node rendered, and the varispeed merely consumes them faster or slower.
- (BOOL)connectNode:(AVAudioPlayerNode *)node throughVarispeedWithFormat:(AVAudioFormat *)format {
    @try {
        [_engine connect:node to:self.varispeed format:format];
        [_engine connect:self.varispeed to:_engine.mainMixerNode format:format];
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: engine connect failed for format %@: %@", format, exception);
        return NO;
    }
    // The IVAR, not self.pitch: the public accessor takes _stateLock, which
    // this already holds, and os_unfair_lock is not recursive — going through
    // the property here aborts the process on the first play.
    os_unfair_lock_lock(&_stateLock);
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    self.varispeed.rate = 1.0f + pitch / 100.0f;
    return YES;
}

// A detach that cannot throw. After a failed connect, a node can be in a state
// that AVAudioEngine's RemoveNode refuses, raising an NSException, and leaking
// the node beats crashing on an already-failing path.
- (void)detachNodeAfterFailedConnect:(AVAudioNode *)node {
    @try {
        [_engine detachNode:node];
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: detach after failed connect: %@", exception);
    }
}

- (AVAudioPlayerNode *)attachConnectedNodeForFormat:(AVAudioFormat *)format {
    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:node];
    if (![self connectNode:node throughVarispeedWithFormat:format]) {
        [self detachNodeAfterFailedConnect:node];
        [self resetToStoppedStateOnQueue];
        return nil;
    }
    return node;
}

- (void)abandonNodeAfterFailedStart:(AVAudioPlayerNode *)node {
    _segmentGeneration++; // drop the scheduled segment's stop-fired completion
    [node stop];
    [_engine detachNode:node];
    [self resetToStoppedStateOnQueue];
}

// Schedules the remainder of the file from startFrame, with a completion
// tagged by the current generation. TRAP: AVAudioPlayerNode fires completions
// on stop and reschedule too, not only at a natural end, so every interruption
// — skip, seek, device switch, a new play — bumps _segmentGeneration first and
// those completions are dropped.
- (void)scheduleFile:(AVAudioFile *)file onNode:(AVAudioPlayerNode *)node fromFrame:(AVAudioFramePosition)startFrame {
    uint64_t gen = _segmentGeneration;
    uint64_t remainingFrames = VibeAudioFramesToSchedule(file.length, startFrame);
    AVAudioPlayerNodeCompletionCallbackType completionType = AVAudioPlayerNodeCompletionDataPlayedBack;
#if DEBUG
    // DataPlayedBack never fires under --no-audio-hw's manual rendering:
    // "played back" is computed against the output device's timeline, which
    // doesn't exist. DataRendered is the same moment at manual mode's zero
    // output latency, and without it track end — and so auto-advance — never
    // fires.
    if (_engine.isInManualRenderingMode) {
        completionType = AVAudioPlayerNodeCompletionDataRendered;
    }
#endif
    __weak AudioPlayer *weakSelf = self;
    AVAudioPlayerNodeCompletionHandler finalCompletion =
            ^(AVAudioPlayerNodeCompletionCallbackType callbackType) {
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(strongSelf->_queue, ^{
                [strongSelf segmentDidCompleteWithGeneration:gen];
            });
        }
    };
    AVAudioFramePosition chunkStart = startFrame;
    while (remainingFrames > 0) {
        AVAudioFrameCount chunkFrames = VibeAudioScheduleChunkFrames(remainingFrames);
        remainingFrames -= chunkFrames;
        // Segments with nil times run consecutively in scheduling order. Only
        // the last chunk owns track completion; an intermediate callback would
        // look exactly like a natural end to the player and advance early.
        AVAudioPlayerNodeCompletionHandler completion = remainingFrames == 0
                ? finalCompletion : nil;
        [node scheduleSegment:file
                startingFrame:chunkStart
                   frameCount:chunkFrames
                       atTime:nil
       completionCallbackType:completionType
            completionHandler:completion];
        chunkStart += chunkFrames;
    }
}

@end
