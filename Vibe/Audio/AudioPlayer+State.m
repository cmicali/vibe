//
//  AudioPlayer+State.m
//  Vibe
//
//  Every getter copies scalars under _stateLock and computes off it; the
//  position adds the voice's snapshot, never a player-queue wait.
//

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

- (BOOL)outputIdle {
    os_unfair_lock_lock(&_stateLock);
    BOOL idle = _outputIdle;
    os_unfair_lock_unlock(&_stateLock);
    return idle;
}

- (NSTimeInterval)duration {
    os_unfair_lock_lock(&_stateLock);
    double sampleRate = _fileSampleRate;
    NSUInteger length = _window.length;
    BOOL loaded = _file != nil;
    os_unfair_lock_unlock(&_stateLock);
    if (!loaded || sampleRate <= 0) {
        return 0;
    }
    return (NSTimeInterval)length / sampleRate;
}

#if DEBUG
// Debug-only, declared in AudioPlayer+Debug.h: dump_state is the one caller.
- (NSUInteger)numChannels {
    os_unfair_lock_lock(&_stateLock);
    AudioFileHandle *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    return file.processingFormat.channelCount;
}
#endif

// Where in the window the voice began plus what it has rendered since, less
// the frames of a file it was promoted out of. Bus and file frames agree in
// seconds at any bus rate, and under the pitch fader this advances with the
// audio.
- (NSTimeInterval)position {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    VibeVoiceID voice = _voice;
    BOOL loaded = _file != nil;
    double fileSampleRate = _fileSampleRate;
    NSUInteger windowLength = _window.length;
    double busSampleRate = _busSampleRate;
    NSTimeInterval startSeconds = _voiceStartSeconds;
    uint64_t baseFrames = _promotedBaseFrames;
    AudioVoiceBus *bus = _voiceBus; // retained here, since the queue may drop it
    os_unfair_lock_unlock(&_stateLock);
    if (!loaded || !voice || fileSampleRate <= 0 || busSampleRate <= 0
            || state == VibePlayerStateStopped || state == VibePlayerStateLoading) {
        return 0;
    }
    VibeVoiceSnapshot snapshot = [bus snapshotOfVoice:voice];
    uint64_t consumed = snapshot.state == VibeVoiceStateNone ? 0 : snapshot.consumed;
    NSTimeInterval rendered = consumed > baseFrames ? (NSTimeInterval)(consumed - baseFrames) / busSampleRate : 0;
    NSTimeInterval duration = (NSTimeInterval)windowLength / fileSampleRate;
    return clampRange(startSeconds + rendered, 0, duration);
}

- (BOOL)isGaplessArmed {
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _gaplessArmedForUI;
    os_unfair_lock_unlock(&_stateLock);
    return armed;
}

@end
