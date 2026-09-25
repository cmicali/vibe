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

// Every gate is checked here, at arming time; the bus refuses on its own if
// the voice's stream has already ended.
- (void)maybeArmSuccessorOnQueue {
    if (_successorTrack || !_voice || !_prefetchedFile || !_prefetchedTrack) {
        return;
    }
    if (_state != VibePlayerStatePlaying && _state != VibePlayerStatePaused) {
        return;
    }
    if (!VibeGaplessArmAllowed(self.crossfadeMilliseconds)) {
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
    if (![_voiceBus queueSuccessor:_prefetchedFile forVoice:_voice]) {
        return;
    }
    _successorTrack = _prefetchedTrack;
    _successorFile = _prefetchedFile;
    [self setSuccessorArmedForUI:YES];
}

// The decoder may have won: once it has switched into the successor, its
// frames are in the ring behind the current file's, and withdrawing the
// metadata alone leaves them to play under a track the UI still names, with
// no boundary to promote and no end to report. Only a new voice discards
// them, so the current file is re-voiced at its position.
- (void)unqueueSuccessorOnQueue {
    BOOL withdrawn = !_voice || [_voiceBus unqueueSuccessorForVoice:_voice];
    [self clearSuccessorOnQueue];
    if (!withdrawn && _file) {
        [self revoiceOnQueueAtPosition:self.position];
    }
}

// The boundary passed: the successor is sounding on the same voice. Promote
// it in place — no stop, no fade, no graph mutation — with the bus frames
// consumed before it as the new base for the position math. The park is
// consumed with it, so a replay of the promoted row opens its own file.
- (void)promoteSuccessorOnQueue {
    AudioTrack *finishedTrack = self.currentTrack;
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
    [self publishState:_state voice:_voice file:startedFile startSeconds:0 baseFrames:snapshot.boundary];
    self.currentTrack = startedTrack;
    startedTrack.duration = self.duration;
    [self armSignalProbeOnQueue:@"gapless boundary"];
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    // Snapshot-guarded like every delivery: a play or stop queued behind this
    // promote rewrites currentTrack before the hop lands, and advancing the
    // playlist for a superseded splice would strand it one row ahead.
    run_on_main_thread({
        if (self.currentTrack != startedTrack || ![self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]) {
            return;
        }
        [self.delegate audioPlayer:self didAutoAdvanceFromTrack:finishedTrack toTrack:startedTrack];
    });
}

#pragma mark - The park

// Supersedes delivery and releases every field which could make a later
// same-path prefetch look parked or still in flight.
- (void)clearPrefetchOnQueue {
    _prefetchGeneration++;
    [_prefetchOpenToken cancel];
    _prefetchOpenToken = nil;
    _prefetchedPath = nil;
    _prefetchedFile = nil;
    _prefetchedTrack = nil;
}

- (void)retirePrefetchOnQueueAtPoint:(VibeAudioPrefetchRetirementPoint)point
                            playPath:(NSString *)playPath {
    if (VibeAudioPrefetchShouldRetire(point, _prefetchedPath, playPath)) {
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
        _requestedPrefetchPath = nil;
    }
}

- (void)beginPrefetchRequestOnQueueForTrack:(AudioTrack *)track {
    _prefetchRequestState = VibeAudioPrefetchRequestBegin(_prefetchRequestState).state;
    _requestedPrefetchTrack = track;
    _requestedPrefetchPath = track.url.path;
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
    NSString *path = _requestedPrefetchPath;
    VibePlaybackRequest *pending = self.pendingRequest.currentRequest;
    VibeAudioPrefetchDisposition disposition = VibeAudioPrefetchDispositionForState(
            path, _prefetchedPath, _prefetchedFile != nil, _prefetchOpenToken != nil, pending.path);
    if (disposition == VibeAudioPrefetchDispositionSuppressBehindPlayback) {
        // The one path that keeps the request ACTIVE: the retained target is
        // what playbackDidSucceedForPrefetchOnQueue resumes.
        _prefetchRequestState = VibeAudioPrefetchRequestSuppressBehindPlayback(
                _prefetchRequestState, requestIdentifier).state;
        return;
    }
    // The queued successor must track the prefetch target. When the
    // playlist's next changes under it — a convert swap of that row, or the
    // parked handle being dropped — the voice would continue into the wrong
    // file at the boundary, so unqueue it.
    if (_successorTrack && (!path || ![path isEqualToString:_successorTrack.url.path])) {
        [self unqueueSuccessorOnQueue];
    }
    if (disposition == VibeAudioPrefetchDispositionReuseParked
            || disposition == VibeAudioPrefetchDispositionJoinPrefetchClaim) {
        // Already parked, or that open is still in flight. A same-path
        // re-prefetch can carry a fresh AudioTrack object, which the promote
        // must deliver; and parked material can be dormant behind a gate
        // that has since opened.
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
    // Claimed at request time rather than at completion, so that repeated
    // prefetches of the same path do not stack opens. _prefetchedFile stays
    // nil until the open lands.
    _prefetchedPath = path;
    _prefetchedTrack = track;
    _prefetchedFile = nil;
    if (!path) {
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
        if (request && [path isEqualToString:request.path]) {
            // A play of this path is waiting on its own interactive claim.
            // Deliver on success only; whichever result consumes the request
            // first detaches the other, and delivery follows the latest
            // rebound row through PlaybackRequestCoordinator.
            if (prefetchGeneration == strongSelf->_prefetchGeneration) {
                [strongSelf clearPrefetchOnQueue];
            }
            if (file && file.length > 0) {
                [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:request.identifier];
            }
            return;
        }
        if (prefetchGeneration != strongSelf->_prefetchGeneration) {
            return; // a newer prefetch target, or an adoption, superseded this open
        }
        if (file && file.length > 0) {
            strongSelf->_prefetchedFile = file;
            [strongSelf maybeArmSuccessorOnQueue];
        }
        else {
            // The open failed. Release the claim so that a play of this track
            // runs its own open and reports the error the usual way.
            [strongSelf clearPrefetchOnQueue];
        }
    }];
    // Every non-suppressed disposition ends the request here: with no
    // acknowledgement to time, the request's remaining job — carrying the
    // target for a suppressed resume — is over the moment its disposition is
    // applied. The open above completes into _prefetchedFile on its own.
    [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
}

@end
