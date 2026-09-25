//
//  AudioPlayer+State.m
//  Vibe
//
//  The public surface is the (State) category in AudioPlayer.h; the state it
//  reads, and the lock that guards it, are AudioPlayerInternal.h's. Every
//  getter takes the lock, copies scalars, and computes off it; the position
//  reads the current voice's consumed frames through the bus's short table
//  lock and atomic snapshot, without waiting on the player queue.
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

- (NSTimeInterval)duration {
    os_unfair_lock_lock(&_stateLock);
    double sampleRate = _fileSampleRate;
    AVAudioFramePosition length = _fileLength;
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

// Playhead in file seconds: where the voice began plus what it has rendered
// since, less the frames that belonged to a file it has since been promoted
// out of. Bus frames and file frames agree in seconds whatever the bus's
// rate, and under the pitch fader the bus is pulled faster, so this advances
// with the audio, as it should.
- (NSTimeInterval)position {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    VibeVoiceID voice = _voice;
    BOOL loaded = _file != nil;
    double fileSampleRate = _fileSampleRate;
    AVAudioFramePosition fileLength = _fileLength;
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
    NSTimeInterval duration = (NSTimeInterval)fileLength / fileSampleRate;
    return clampRange(startSeconds + rendered, 0, duration);
}

// The queued-successor mirror, written under the lock by the prefetch code so
// this can answer without touching the queue at all.
- (BOOL)isGaplessArmed {
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _gaplessArmedForUI;
    os_unfair_lock_unlock(&_stateLock);
    return armed;
}

@end
