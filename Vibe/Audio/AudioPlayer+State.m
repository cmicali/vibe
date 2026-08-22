//
//  AudioPlayer+State.m
//  Vibe
//

// The public surface is the (State) category in AudioPlayer.h; the state it
// reads, and the lock that guards it, are AudioPlayerInternal.h's.
//
// position is the subtle one, and its two hazards are commented at the site: a
// node this getter is reading can be detached concurrently by the queue, and
// raises rather than answering nil; and the value it computes off-lock can be
// superseded by a seek or a track change before it is stored back.
//
// The single writer of everything here is publishPlaybackState:, in
// AudioPlayer.m, and the fields stay readonly on the shared surface so that
// keeping it the single writer is a compile error to get wrong. The one
// exception is _lastValidPosition, which the position getter writes back under
// the epoch check.

#import "AudioPlayerInternal.h"

@implementation AudioPlayer (State)

- (BOOL)isPlaying {
    os_unfair_lock_lock(&_stateLock);
    BOOL playing = (_state == VibePlayerStatePlaying
            || (_state == VibePlayerStateLoading && !self.loadingStartPaused));
    os_unfair_lock_unlock(&_stateLock);
    return playing;
}

- (BOOL)isPaused {
    os_unfair_lock_lock(&_stateLock);
    BOOL paused = (_state == VibePlayerStatePaused
            || (_state == VibePlayerStateLoading && self.loadingStartPaused));
    os_unfair_lock_unlock(&_stateLock);
    return paused;
}

- (BOOL)isLoading {
    os_unfair_lock_lock(&_stateLock);
    BOOL loading = (_state == VibePlayerStateLoading);
    os_unfair_lock_unlock(&_stateLock);
    return loading;
}

- (BOOL)isStopped {
    os_unfair_lock_lock(&_stateLock);
    BOOL stopped = (_state == VibePlayerStateStopped);
    os_unfair_lock_unlock(&_stateLock);
    return stopped;
}

- (BOOL)outputAudioActive {
    os_unfair_lock_lock(&_stateLock);
    BOOL active = _outputAudioActive;
    os_unfair_lock_unlock(&_stateLock);
    return active;
}

- (NSTimeInterval)duration {
    os_unfair_lock_lock(&_stateLock);
    AVAudioFile *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    double sampleRate = file.processingFormat.sampleRate;
    if (!file || sampleRate <= 0) {
        return 0;
    }
    return (NSTimeInterval)file.length / sampleRate;
}

- (NSUInteger)numChannels {
    os_unfair_lock_lock(&_stateLock);
    AVAudioFile *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    return file.processingFormat.channelCount;
}

- (NSTimeInterval)position {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    AVAudioPlayerNode *node = _node;
    AVAudioFile *file = _file;
    AVAudioFramePosition segmentStartFrame = _segmentStartFrame;
    NSTimeInterval pausedPosition = self.pausedPosition;
    NSTimeInterval lastValidPosition = _lastValidPosition;
    uint64_t positionEpoch = self.positionEpoch;
    os_unfair_lock_unlock(&_stateLock);

    if (!file || state == VibePlayerStateStopped) {
        return 0;
    }
    double sampleRate = file.processingFormat.sampleRate;
    if (sampleRate <= 0) {
        return 0;
    }
    if (state == VibePlayerStatePaused || !node) {
        return pausedPosition;
    }
    // playerTime restarts at 0 after every stop+reschedule, so the segment's
    // start frame must always be added back.
    AVAudioTime *playerTime = nil;
    @try {
        // The queue can detach this node concurrently, on fast skips, because
        // the snapshot above is deliberately used off the lock, and a detached
        // node's lastRenderTime raises when _engine is non-nil rather than
        // returning nil. Treat that as no reading: the fallback below serves the last
        // valid position, and the next tick reads the replacement node.
        AVAudioTime *nodeTime = node.lastRenderTime;
        // A stopped engine's node hands back a non-nil time with BOTH validity
        // flags false, and playerTimeForNodeTime: error-logs on every such
        // call — at the UI tick rate, for as long as the engine stays down.
        // The invalid reading means the same thing nil does: no reading.
        playerTime = nodeTime && (nodeTime.sampleTimeValid || nodeTime.hostTimeValid)
                ? [node playerTimeForNodeTime:nodeTime] : nil;
    }
    @catch (NSException *exception) {
        playerTime = nil;
    }
    NSTimeInterval position;
    if (!playerTime || !playerTime.sampleTimeValid) {
        // Either nothing has rendered yet, right after a play, or the engine
        // stopped itself on a device unplug or format change, since
        // lastRenderTime is nil while stopped. On iOS the player's own sampler
        // keeps this cache current while the backgrounded screen timer is
        // dormant. Within one segment the last valid reading is never behind
        // the segment start, so MAX covers both cases.
        position = MAX((NSTimeInterval)segmentStartFrame / sampleRate, lastValidPosition);
    }
    else {
        position = (NSTimeInterval)(segmentStartFrame + playerTime.sampleTime) / sampleRate;
    }
    NSTimeInterval duration = (NSTimeInterval)file.length / sampleRate;
    position = MIN(MAX(position, 0), duration);
    if (playerTime && playerTime.sampleTimeValid) {
        os_unfair_lock_lock(&_stateLock);
        // A seek, pause or track change may have rewritten the position state
        // while this was computed off-lock, and storing it then would
        // resurrect the pre-seek position. The stale reading is not returned
        // upward either: the epoch writer's value is the truth now.
        if (self.positionEpoch == positionEpoch) {
            _lastValidPosition = position;
        }
        else {
            position = _lastValidPosition;
        }
        os_unfair_lock_unlock(&_stateLock);
    }
    return position;
}

// The armed-splice mirror, written under the lock by setGaplessQueuedOnQueue:
// so this can answer without touching the queue at all; see AudioPlayer+Gapless.
- (BOOL)isGaplessArmed {
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _gaplessArmedForUI;
    os_unfair_lock_unlock(&_stateLock);
    return armed;
}

@end
