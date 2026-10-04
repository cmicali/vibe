//
//  AudioPlayer+Prefetch.m
//  Vibe
//

#import "AudioPlayer+Prefetch.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"

@interface AudioPlayer (PrefetchPrivate)
- (void)beginPrefetchRequestOnQueueForTrack:(nullable AudioTrack *)track;
- (void)settlePrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier;
- (void)processPrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier;
@end

@implementation AudioPlayer (Prefetch)

#pragma mark - The successor

- (void)setSuccessorArmedForUI:(BOOL)armed {
    os_unfair_lock_lock(&_stateLock);
    _gaplessArmedForUI = armed;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)clearSuccessorOnQueue {
    _successorTrack = nil;
    _successorFile = nil;
    [self setSuccessorArmedForUI:NO];
}

// Only a declick can splice two tracks, except the next window of the file,
// which continues its recording whatever the crossfade.
- (BOOL)gaplessArmAllowedOnQueue {
    return VibeGaplessArmAllowed(self.crossfadeMilliseconds, [self.currentTrack isFollowedContiguouslyBy:_prefetchedTrack]);
}

// Every gate is checked here, at arming time; the bus refuses on its own if
// the voice's stream has already ended.
- (void)maybeArmSuccessorOnQueue {
    if (_successorTrack || !_voice || !_prefetchedFile || !_prefetchedTrack) {
        return;
    }
    if (_state != VibePlayerStatePlaying && _state != VibePlayerStatePaused) {
        return;
    }
    if (!self.gaplessArmAllowedOnQueue) {
        return;
    }
#if TARGET_OS_OSX
    // A splice keeps the bus at the current file's format — its channel order
    // included — and the device's too, so under bit-perfect output the next
    // file must want both; a boundary that needs a switch or a rebuild takes
    // the ordinary track end instead.
    if (_bitPerfectWanted && (!VibePCMFormatsMatch(_file.processingFormat, _prefetchedFile.processingFormat)
            || [self outputNeedsSwitchOnQueueForFile:_prefetchedFile])) {
        return;
    }
#endif
    NSRange window = [_prefetchedTrack frameWindowInFile:_prefetchedFile estimated:NULL];
    if (window.length == 0
            || ![_voiceBus queueSuccessor:_prefetchedFile startFrame:(AVAudioFramePosition)window.location
                                 endFrame:[_prefetchedTrack endFrameInFile:_prefetchedFile] forVoice:_voice]) {
        return;
    }
    _successorTrack = _prefetchedTrack;
    _successorFile = _prefetchedFile;
    [self setSuccessorArmedForUI:YES];
}

// The decoder may have won: the successor's frames are in the ring, and only
// a new voice discards them, so the current file is re-voiced at its position.
// Withdrawn in metadata alone, they play under the wrong title, with no
// boundary to promote and no end to report.
- (void)unqueueSuccessorOnQueue {
    BOOL withdrawn = !_voice || [_voiceBus unqueueSuccessorForVoice:_voice];
    [self clearSuccessorOnQueue];
    if (!withdrawn && _file) {
        [self revoiceOnQueueAtPosition:self.position];
    }
}

// In place, with the bus frames consumed before the boundary as the position's
// new base. The park is consumed with it, so a replay of the promoted row opens
// its own file.
- (void)promoteSuccessorOnQueue {
    AudioTrack *startedTrack = _successorTrack;
    AudioFileHandle *startedFile = _successorFile;
    if (!startedTrack || !startedFile) {
        return;
    }
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:_voice];
    [self clearSuccessorOnQueue];
    if ([_prefetchedFile isEqual:startedFile]) {
        [self clearPrefetchOnQueue];
    }
    // At its window's start, where the bus began the successor; a settle
    // after the window is taken is republished.
    BOOL estimated = NO;
    NSRange window = [startedTrack frameWindowInFile:startedFile estimated:&estimated];
    [self adoptTrack:startedTrack file:startedFile window:window estimated:estimated
               voice:_voice baseFrames:snapshot.boundary reason:@"gapless boundary"];
}

// A long crossfade's track end: the park starts as a voice of its own while
// the current one fades out beside it, the promote's delivery without its
// splice. Without this a long crossfade only lost gapless: the track played
// out, and the shell's play: of the next found nothing audible to fade from.
- (void)maybeCrossfadeIntoParkOnQueue {
    AudioTrack *startedTrack = _prefetchedTrack;
    AudioFileHandle *startedFile = _prefetchedFile;
    if (_successorTrack || !startedTrack || !startedFile || startedFile == _file
            || _state != VibePlayerStatePlaying || _buffering || _windowEstimated
            || [self bitPerfectOnQueue] || ![self renderingOnQueue]) {
        return;
    }
    BOOL estimated = NO;
    NSRange window = [startedTrack frameWindowInFile:startedFile estimated:&estimated];
    if (window.length == 0) {
        return; // the shell's play: of it reports the error at the track end
    }
    NSTimeInterval duration = self.duration;
    NSTimeInterval nextDuration = (NSTimeInterval)window.length / startedFile.processingFormat.sampleRate;
    uint64_t milliseconds = VibeTrackEndCrossfadeMilliseconds(self.crossfadeMilliseconds, duration - self.position, duration,
                                                              nextDuration, (NSTimeInterval)kDrainSteadyIntervalNanos / NSEC_PER_SEC);
    if (milliseconds == 0) {
        return;
    }
    [self clearPrefetchOnQueue];
    VibeVoiceID outgoing = [self unpublishVoiceOnQueue];
    [self retireVoiceOnQueue:outgoing milliseconds:milliseconds];
    VibeVoiceID voice = [self startVoiceOnQueueForFile:startedFile atFrame:(AVAudioFramePosition)window.location
                                              endFrame:[startedTrack endFrameInFile:startedFile]
                                      fadeMilliseconds:milliseconds paused:NO];
    [self adoptTrack:startedTrack file:startedFile window:window estimated:estimated
               voice:voice baseFrames:0 reason:@"track-end crossfade"];
}

// Both auto-advances end here: the started track is current at its window's
// start on `voice`, `baseFrames` being the bus frames that voice consumed
// before it, and the shell is told.
- (void)adoptTrack:(AudioTrack *)startedTrack file:(AudioFileHandle *)file window:(NSRange)window
         estimated:(BOOL)estimated voice:(VibeVoiceID)voice baseFrames:(uint64_t)baseFrames reason:(NSString *)reason {
    AudioTrack *finishedTrack = self.currentTrack;
    _windowEstimated = estimated;
    [self publishState:_state voice:voice file:file window:window startSeconds:0 baseFrames:baseFrames];
    self.currentTrack = startedTrack;
    startedTrack.duration = self.duration;
    [self armSignalProbeOnQueue:reason];
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    // A play or stop queued behind this rewrites currentTrack before the hop
    // lands; advancing for a superseded one strands the playlist a row ahead.
    run_on_main_thread({
        if (self.currentTrack != startedTrack || ![self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]) {
            return;
        }
        [self.delegate audioPlayer:self didAutoAdvanceFromTrack:finishedTrack toTrack:startedTrack];
    });
}

#pragma mark - The park

// Supersedes delivery and releases every field which could make a later
// prefetch of the same track look parked or still in flight.
- (void)clearPrefetchOnQueue {
    _prefetchGeneration++;
    [_prefetchOpenToken cancel];
    _prefetchOpenToken = nil;
    _prefetchedKey = nil;
    _prefetchedFile = nil;
    _prefetchedTrack = nil;
}

- (void)retirePrefetchOnQueueAtPoint:(VibeAudioPrefetchRetirementPoint)point
                             playKey:(NSString *)playKey {
    if (VibeAudioPrefetchShouldRetire(point, _prefetchedKey, playKey)) {
        [self clearPrefetchOnQueue];
    }
    if (point == VibeAudioPrefetchAtAbandonment) {
        [self terminallyRetirePrefetchRequestOnQueue];
    }
}

- (void)applyPrefetchRequestTransitionOnQueue:(VibeAudioPrefetchRequestTransition)transition {
    _prefetchRequestState = transition.state;
    if (!_prefetchRequestState.requestActive) {
        _requestedPrefetchTrack = nil;
        _requestedPrefetchKey = nil;
    }
}

- (void)beginPrefetchRequestOnQueueForTrack:(AudioTrack *)track {
    _prefetchRequestState = VibeAudioPrefetchRequestBegin(_prefetchRequestState).state;
    _requestedPrefetchTrack = track;
    _requestedPrefetchKey = track.sourceKey;
}

- (void)settlePrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier {
    [self applyPrefetchRequestTransitionOnQueue:
            VibeAudioPrefetchRequestFinish(_prefetchRequestState, requestIdentifier)];
}

- (void)terminallyRetirePrefetchRequestOnQueue {
    [self settlePrefetchRequestOnQueueForIdentifier:_prefetchRequestState.currentRequestIdentifier];
}

- (void)playbackDidSucceedForPrefetchOnQueue {
    uint64_t requestIdentifier = _prefetchRequestState.currentRequestIdentifier;
    VibeAudioPrefetchRequestTransition transition =
            VibeAudioPrefetchRequestPlaybackSucceeded(_prefetchRequestState, requestIdentifier);
    [self applyPrefetchRequestTransitionOnQueue:transition];
    if (transition.action & VibeAudioPrefetchRequestActionResume) {
        [self processPrefetchRequestOnQueueForIdentifier:requestIdentifier];
    }
}

- (void)prefetchOnQueue:(AudioTrack *)track {
    if (_terminating) {
        return;
    }
    [self beginPrefetchRequestOnQueueForTrack:track];
    [self processPrefetchRequestOnQueueForIdentifier:_prefetchRequestState.currentRequestIdentifier];
}

- (void)processPrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier {
    if (!_prefetchRequestState.requestActive
            || requestIdentifier != _prefetchRequestState.currentRequestIdentifier) {
        return;
    }
    AudioTrack *track = _requestedPrefetchTrack;
    NSString *key = _requestedPrefetchKey;
    VibePlaybackRequest *pending = self.pendingRequest.currentRequest;
    // By the pending play's track, not its path: another window of the file
    // being opened is a prefetch of its own, parked behind that open.
    VibeAudioPrefetchDisposition disposition = VibeAudioPrefetchDispositionForState(
            key, _prefetchedKey, _prefetchedFile != nil, _prefetchOpenToken != nil, pending.track.sourceKey);
    if (disposition == VibeAudioPrefetchDispositionSuppressBehindPlayback) {
        // The one path that keeps the request ACTIVE: the retained target is
        // what playbackDidSucceedForPrefetchOnQueue resumes.
        _prefetchRequestState = VibeAudioPrefetchRequestSuppressBehindPlayback(
                _prefetchRequestState, requestIdentifier).state;
        return;
    }
    // The successor must track the prefetch target, or the voice continues
    // into the wrong file at the boundary.
    if (_successorTrack && (!key || ![key isEqualToString:_successorTrack.sourceKey])) {
        [self unqueueSuccessorOnQueue];
    }
    if (disposition == VibeAudioPrefetchDispositionReuseParked
            || disposition == VibeAudioPrefetchDispositionJoinPrefetchClaim) {
        // A re-prefetch of the same track can carry a fresh AudioTrack object,
        // which the promote must deliver, and a gate may have opened since.
        _prefetchedTrack = track;
        if (_successorTrack) {
            _successorTrack = track;
        }
        else {
            [self maybeArmSuccessorOnQueue];
        }
        [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
        return;
    }
    if (disposition == VibeAudioPrefetchDispositionJoinPlaybackClaim) {
        [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
        return; // being opened for playback right now
    }
    [self clearPrefetchOnQueue];
    // Claimed at request time, so repeated prefetches of a track do not stack
    // opens.
    _prefetchedKey = key;
    _prefetchedTrack = track;
    _prefetchedFile = nil;
    if (!key) {
        [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
        return; // nil track means end of playlist: just drop the parked handle
    }
    uint64_t prefetchGeneration = _prefetchGeneration;
    __weak AudioPlayer *weakSelf = self;
    _prefetchOpenToken = [[AudioFileMaterializationCoordinator sharedCoordinator]
            openURL:track.url
            purpose:VibeAudioFileOpenPurposePrefetch
            completionQueue:_queue
            completion:^(AudioFileHandle *file, NSError *error, NSTimeInterval elapsed) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (prefetchGeneration == strongSelf->_prefetchGeneration) {
            strongSelf->_prefetchOpenToken = nil;
        }
        VibePlaybackRequest *request = strongSelf.pendingRequest.currentRequest;
        if (request && [key isEqualToString:request.track.sourceKey]) {
            // A play of this track is waiting on its own claim. Deliver on
            // success only, and never under a decoder choice since changed,
            // which the play's own open reflects; whichever result consumes
            // the request first detaches the other.
            if (prefetchGeneration == strongSelf->_prefetchGeneration) {
                [strongSelf clearPrefetchOnQueue];
            }
            if (file && file.length > 0 && !file.decoderChoiceIsStale) {
                [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:request.identifier];
            }
            return;
        }
        if (prefetchGeneration != strongSelf->_prefetchGeneration) {
            return; // a newer prefetch target, or an adoption, superseded this open
        }
        if (file.decoderChoiceIsStale) {
            // The decoder changed while this open ran, and a re-prefetch of
            // its track joined the run instead of restarting it. It has
            // settled now, so this opens under the current choice.
            [strongSelf clearPrefetchOnQueue];
            [strongSelf prefetchOnQueue:track];
        }
        else if (file && file.length > 0) {
            strongSelf->_prefetchedFile = file;
            [strongSelf maybeArmSuccessorOnQueue];
        }
        else {
            // A play of this track then runs its own open and reports the
            // error.
            [strongSelf clearPrefetchOnQueue];
        }
    }];
    // Every non-suppressed disposition ends the request here; the open
    // completes into _prefetchedFile on its own.
    [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
}

@end
