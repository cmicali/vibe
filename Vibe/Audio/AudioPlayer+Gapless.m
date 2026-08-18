//
//  AudioPlayer+Gapless.m
//  Vibe
//

#import "AudioPlayer+Gapless.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "GaplessSpliceMath.h"

@interface AudioPlayer (GaplessPrivate)
- (void)beginPrefetchRequestOnQueueForTrack:(nullable AudioTrack *)track
                                    claimed:(nullable dispatch_block_t)claimed;
- (void)settlePrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier;
- (void)resolvePrefetchRequestOnQueue;
- (void)processPrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier;
@end

@implementation AudioPlayer (Gapless)

// Sole writer of _gaplessQueued, keeping the lock-free mirror in step.
- (void)setGaplessQueuedOnQueue:(BOOL)queued {
    _gaplessQueued = queued;
    os_unfair_lock_lock(&_stateLock);
    _gaplessArmedForUI = queued;
    os_unfair_lock_unlock(&_stateLock);
}

// Drops the armed material entirely. Safe only where the queued segment is
// dead or dying — the node stopped, retiring or detached — or was never
// scheduled; unscheduleGaplessOnQueue is the path for a live one.
- (void)clearGaplessOnQueue {
    [self setGaplessQueuedOnQueue:NO];
    _gaplessTrack = nil;
    _gaplessFile = nil;
    [_gaplessOpenToken cancel];
    _gaplessOpenToken = nil;
    _gaplessOpenPath = nil;
    _gaplessOpenRequestId++; // supersede any in-flight gapless open
}

// Acquires the splice's private handle for the prefetched next track, then
// arms. The gates are checked here only to skip a pointless open;
// maybeArmGaplessOnQueue re-checks them at scheduling time.
- (void)maybeOpenGaplessFileForTrack:(AudioTrack *)track prefetchedFile:(AVAudioFile *)prefetchedFile {
    if ([track.url.path isEqualToString:_gaplessOpenPath]) {
        return; // this open is already in flight; re-kicking it would only churn fds
    }
    if (!VibeGaplessArmAllowed(self.crossfadeMilliseconds)) {
        return;
    }
    AVAudioFile *currentFile = _file;
    if (!currentFile || !VibeGaplessFormatsMatch(currentFile.processingFormat.sampleRate,
                                                 currentFile.processingFormat.channelCount,
                                                 prefetchedFile.processingFormat.sampleRate,
                                                 prefetchedFile.processingFormat.channelCount)) {
        return;
    }
    uint64_t openId = ++_gaplessOpenRequestId;
    NSString *path = track.url.path;
    _gaplessOpenPath = path;
    __weak AudioPlayer *weakSelf = self;
    _gaplessOpenToken = [[AudioFileOpenCoordinator sharedCoordinator]
            openURL:track.url
            purpose:VibeAudioFileOpenPurposeGapless
            completionQueue:_queue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (openId != strongSelf->_gaplessOpenRequestId) {
            return; // superseded: a clear, a newer target, or a promote
        }
        strongSelf->_gaplessOpenToken = nil;
        strongSelf->_gaplessOpenPath = nil; // spent, success or not
        if (!file || file.length <= 0) {
            return; // the classic transition still works off the prefetch park
        }
        // A same-path re-prefetch can replace the playlist with fresh row
        // objects while this private handle is opening. Bind promotion to the
        // current park identity, not to the row captured when the open began.
        AudioTrack *currentTrack = strongSelf->_prefetchedTrack;
        if (!currentTrack || ![currentTrack.url.path isEqualToString:path]) {
            return;
        }
        strongSelf->_gaplessTrack = currentTrack;
        strongSelf->_gaplessFile = file;
        [strongSelf maybeArmGaplessOnQueue];
    }];
}

// Schedules the pre-opened next file as a second segment on the current node.
// Callable from any queue-side point that has just (re)scheduled the current
// segment; it no-ops unless every gate holds. The segment carries the current
// generation deliberately: a stop, seek, skip or device switch invalidates
// both segments' completions together.
- (void)maybeArmGaplessOnQueue {
    if (_gaplessQueued || !_gaplessFile || !_node || !_file) {
        return;
    }
    if (_state != VibePlayerStatePlaying && _state != VibePlayerStatePaused) {
        return;
    }
    if (!VibeGaplessArmAllowed(self.crossfadeMilliseconds)) {
        return;
    }
    if (!VibeGaplessFormatsMatch(_file.processingFormat.sampleRate,
                                 _file.processingFormat.channelCount,
                                 _gaplessFile.processingFormat.sampleRate,
                                 _gaplessFile.processingFormat.channelCount)) {
        return;
    }
    [self scheduleFile:_gaplessFile onNode:_node fromFrame:0];
    [self setGaplessQueuedOnQueue:YES];
}

// The boundary passed: the finished segment's completion fired while the next
// track's segment — already sounding — sits queued on the same node. Promote
// it to current in place: no node stop, no fade, no graph mutation, and no
// idle-stop schedule, because nothing went idle. _segmentGeneration is
// deliberately not bumped — the now-current segment's completion carries it,
// and will route the next boundary or the natural end. The published segment
// start goes negative (GaplessSpliceMath.h); the position getter's math is
// signed and correct on both sides of the publish.
- (void)promoteGaplessOnQueue {
    AVAudioPlayerNode *node = _node;
    AVAudioFile *finishedFile = _file;
    AVAudioFile *startedFile = _gaplessFile;
    AudioTrack *finishedTrack = self.currentTrack;
    AudioTrack *startedTrack = _gaplessTrack;
    [self clearGaplessOnQueue];

    double sampleRate = startedFile.processingFormat.sampleRate;
    AVAudioFramePosition newStart = VibeGaplessPromotedSegmentStart(_segmentStartFrame, finishedFile.length);
    AVAudioTime *playerTime = nil;
    @try {
        AVAudioTime *nodeTime = node.lastRenderTime;
        playerTime = nodeTime ? [node playerTimeForNodeTime:nodeTime] : nil;
    }
    @catch (NSException *exception) {
        playerTime = nil;
    }
    NSTimeInterval position;
    if (playerTime && playerTime.sampleTimeValid) {
        position = (NSTimeInterval)(newStart + playerTime.sampleTime) / sampleRate;
    }
    else {
        // Paused at the boundary, or nothing rendered since: map the last
        // captured position into the promoted timeline. The raw twin keeps
        // the frames the pause's duration clamp discarded past the finished
        // file's end, so resume audio and the label agree.
        NSTimeInterval basis = (_state == VibePlayerStatePaused) ? self.pausedRawPosition : self.position;
        position = basis - (NSTimeInterval)finishedFile.length / finishedFile.processingFormat.sampleRate;
    }
    position = MAX(position, 0);
    [self publishPlaybackState:_state node:node file:startedFile segmentStart:newStart position:position];
    self.currentTrack = startedTrack;
    startedTrack.duration = self.duration;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    // Snapshot-guarded like finishPlaybackOnQueue's delivery: a play or stop
    // queued behind this promote rewrites currentTrack before the hop lands,
    // and advancing the playlist for a superseded splice would strand it one
    // row ahead of what that operation actually plays.
    run_on_main_thread({
        if (self.currentTrack != startedTrack
                || ![self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]) {
            return;
        }
        [self.delegate audioPlayer:self didAutoAdvanceFromTrack:finishedTrack toTrack:startedTrack];
    });
}

// The armed next track is no longer the playlist's next. The only way to
// unqueue a segment from a node is [node stop] plus a reschedule of the
// current remainder, and a bare stop mid-render clicks — so reuse the seek
// path wholesale, which already does the fade-down/reschedule/fade-up dance
// while playing and the silent in-place reschedule while paused. Costs one
// spurious didFinishSeeking:, which only settles the UI.
- (void)unscheduleGaplessOnQueue {
    BOOL wasQueued = _gaplessQueued;
    [self clearGaplessOnQueue];
    if (wasQueued) {
        // The stale segment stays physically queued until the seek's stop
        // lands (a queue hop plus the fade). A boundary inside that window
        // must not finish the track — finishPlaybackOnQueue would bare-stop
        // the node just as the wrong file starts sounding, a blip plus a
        // click — so stale it now; the seek replays the current remainder
        // from here and the re-run boundary advances normally, unarmed.
        _segmentGeneration++;
        [self seekToPosition:self.position];
    }
}


#pragma mark - The park

// Supersedes delivery and releases every field which could make a later
// same-path prefetch look parked or still in flight.
- (void)clearPrefetchOnQueue {
    _prefetchRequestId++;
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

- (void)applyPrefetchAcknowledgementTransitionOnQueue:
        (VibeAudioPrefetchAcknowledgementTransition)transition {
    dispatch_block_t waiter = _prefetchClaimWaiter;
    _prefetchAcknowledgementState = transition.state;
    if (transition.action & VibeAudioPrefetchAcknowledgementActionDeliver) {
        _prefetchClaimWaiter = nil;
        if (waiter) {
            waiter();
        }
    }
    if (!_prefetchAcknowledgementState.requestActive) {
        _requestedPrefetchTrack = nil;
        _requestedPrefetchPath = nil;
        _prefetchClaimWaiter = nil;
        _prefetchClaimObservationToken = nil;
    }
}

- (void)beginPrefetchRequestOnQueueForTrack:(AudioTrack *)track
                                    claimed:(dispatch_block_t)claimed {
    dispatch_block_t retiredWaiter = _prefetchClaimWaiter;
    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementBegin(
                    _prefetchAcknowledgementState, claimed != nil);
    _prefetchAcknowledgementState = transition.state;
    _requestedPrefetchTrack = track;
    _requestedPrefetchPath = track.url.path;
    _prefetchClaimWaiter = [claimed copy];
    _prefetchClaimObservationToken = nil;
    if ((transition.action & VibeAudioPrefetchAcknowledgementActionDeliver)
            && retiredWaiter) {
        retiredWaiter();
    }
}

- (void)settlePrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier {
    [self applyPrefetchAcknowledgementTransitionOnQueue:
            VibeAudioPrefetchAcknowledgementClaimSettled(
                    _prefetchAcknowledgementState, requestIdentifier)];
}

- (void)terminallyRetirePrefetchRequestOnQueue {
    uint64_t requestIdentifier = _prefetchAcknowledgementState.currentRequestIdentifier;
    [self applyPrefetchAcknowledgementTransitionOnQueue:
            VibeAudioPrefetchAcknowledgementTerminallyRetired(
                    _prefetchAcknowledgementState, requestIdentifier)];
}

- (void)playbackDidSucceedForPrefetchOnQueue {
    uint64_t requestIdentifier = _prefetchAcknowledgementState.currentRequestIdentifier;
    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementPlaybackSucceeded(
                    _prefetchAcknowledgementState, requestIdentifier);
    [self applyPrefetchAcknowledgementTransitionOnQueue:transition];
    if (transition.action & VibeAudioPrefetchAcknowledgementActionResume) {
        [self processPrefetchRequestOnQueueForIdentifier:requestIdentifier];
    }
}

- (void)observePrefetchClaimToken:(AudioFileOpenToken *)token
                             path:(NSString *)path
                requestIdentifier:(uint64_t)requestIdentifier {
    if (!token || token == _prefetchClaimObservationToken) {
        return;
    }
    _prefetchClaimObservationToken = token;
    __weak AudioPlayer *weakSelf = self;
    [token whenClaimedOnQueue:_queue completion:^(VibeAudioFileOpenClaimResult result) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf->_prefetchClaimObservationToken == token) {
            strongSelf->_prefetchClaimObservationToken = nil;
        }
        if (!strongSelf->_prefetchAcknowledgementState.requestActive
                || requestIdentifier
                        != strongSelf->_prefetchAcknowledgementState.currentRequestIdentifier) {
            return;
        }
        if ([path isEqualToString:strongSelf->_requestedPrefetchPath]) {
            BOOL currentPrefetchClaim = token == strongSelf->_prefetchOpenToken
                    && [path isEqualToString:strongSelf->_prefetchedPath];
            VibePlaybackRequest *pending = strongSelf.pendingRequest.currentRequest;
            BOOL currentPlaybackClaim = token == strongSelf->_playOpenToken
                    && [path isEqualToString:pending.path];
            if (currentPrefetchClaim || currentPlaybackClaim) {
                // Claimed means the successor is atomically registered;
                // Cancelled means central admission rejected it and no
                // transfer can race the resumed metadata lane. Either verdict
                // settles the shell's ordering wait. Re-observing a Cancelled
                // current token would only enqueue the same verdict forever.
                [strongSelf settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
                return;
            }
        }
        [strongSelf resolvePrefetchRequestOnQueue];
    }];
}

- (void)resolvePrefetchRequestOnQueue {
    if (!_prefetchAcknowledgementState.requestActive) {
        return;
    }
    uint64_t requestIdentifier = _prefetchAcknowledgementState.currentRequestIdentifier;
    NSString *path = _requestedPrefetchPath;
    if (!path) {
        [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
        return;
    }
    if ([path isEqualToString:_prefetchedPath] && _prefetchedFile) {
        [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
        return;
    }
    if ([path isEqualToString:_prefetchedPath] && _prefetchOpenToken) {
        [self observePrefetchClaimToken:_prefetchOpenToken
                                   path:path
                      requestIdentifier:requestIdentifier];
        return;
    }
    VibePlaybackRequest *pending = self.pendingRequest.currentRequest;
    if ([path isEqualToString:pending.path] && _playOpenToken) {
        [self observePrefetchClaimToken:_playOpenToken
                                   path:path
                      requestIdentifier:requestIdentifier];
        return;
    }
    [self settlePrefetchRequestOnQueueForIdentifier:requestIdentifier];
}

// Opens the file on the bounded background lane and parks the handle for
// playOnQueue: to consume. A play arriving mid-open has its own interactive
// lane, while same-path prefetch requests reuse this claim.
- (void)prefetchOnQueue:(AudioTrack *)track whenClaimed:(void (^)(void))claimed {
    [self beginPrefetchRequestOnQueueForTrack:track claimed:claimed];
    [self processPrefetchRequestOnQueueForIdentifier:
            _prefetchAcknowledgementState.currentRequestIdentifier];
}

- (void)processPrefetchRequestOnQueueForIdentifier:(uint64_t)requestIdentifier {
    if (!_prefetchAcknowledgementState.requestActive
            || requestIdentifier != _prefetchAcknowledgementState.currentRequestIdentifier) {
        return;
    }
    AudioTrack *track = _requestedPrefetchTrack;
    NSString *path = _requestedPrefetchPath;
    VibePlaybackRequest *pending = self.pendingRequest.currentRequest;
    VibeAudioPrefetchDisposition disposition = VibeAudioPrefetchDispositionForState(
            path, _prefetchedPath, _prefetchedFile != nil, _prefetchOpenToken != nil,
            pending.path);
    if (disposition == VibeAudioPrefetchDispositionSuppressBehindPlayback) {
        _prefetchAcknowledgementState =
                VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
                        _prefetchAcknowledgementState, requestIdentifier).state;
        return;
    }
    // The armed splice must track the prefetch target. When the playlist's
    // next changes under it — a convert swap of that row, or the parked
    // handle being dropped — the queued segment would play the wrong file at
    // the boundary, so unqueue it (parked-only material just drops).
    if (_gaplessTrack && (!path || ![path isEqualToString:_gaplessTrack.url.path])) {
        [self unscheduleGaplessOnQueue];
    }
    if (disposition == VibeAudioPrefetchDispositionReuseParked
            || disposition == VibeAudioPrefetchDispositionJoinPrefetchClaim) {
        // Already prefetched, or that open is still in flight. The gapless
        // material can still be missing — a park made before the current
        // track started has no format to arm against — so acquire off the
        // parked handle now; and a same-path re-prefetch can carry a fresh
        // AudioTrack object, which the promote must deliver.
        _prefetchedTrack = track;
        if (_gaplessTrack) {
            _gaplessTrack = track;
            // Parked material can be dormant when a transiently closed gate
            // blocked the arm (crossfade toggled on and back off); idempotent
            // when already queued.
            [self maybeArmGaplessOnQueue];
        }
        else if (_prefetchedFile && !_gaplessQueued) {
            [self maybeOpenGaplessFileForTrack:track prefetchedFile:_prefetchedFile];
        }
        [self resolvePrefetchRequestOnQueue];
        return;
    }
    if (disposition == VibeAudioPrefetchDispositionJoinPlaybackClaim) {
        [self resolvePrefetchRequestOnQueue];
        return; // being opened for playback right now
    }
    [self clearPrefetchOnQueue];
    if (_gaplessOpenPath) {
        // The second-handle open tracks the prefetch target too. While it is
        // in flight _gaplessTrack is still nil, so the unschedule guard above
        // could not see the retarget; left alive, the stale track would arm
        // at completion and the boundary would render the wrong file.
        _gaplessOpenRequestId++;
        [_gaplessOpenToken cancel];
        _gaplessOpenToken = nil;
        _gaplessOpenPath = nil;
    }
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
    uint64_t prefetchId = _prefetchRequestId;
    __weak AudioPlayer *weakSelf = self;
    _prefetchOpenToken = [[AudioFileOpenCoordinator sharedCoordinator]
            openURL:track.url
            purpose:VibeAudioFileOpenPurposePrefetch
            completionQueue:_queue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (prefetchId == strongSelf->_prefetchRequestId) {
            strongSelf->_prefetchOpenToken = nil;
            if ([path isEqualToString:strongSelf->_requestedPrefetchPath]) {
                [strongSelf settlePrefetchRequestOnQueueForIdentifier:
                        strongSelf->_prefetchAcknowledgementState.currentRequestIdentifier];
            }
        }
        VibePlaybackRequest *request = strongSelf.pendingRequest.currentRequest;
        if (request && [path isEqualToString:request.path]) {
            // A play of this path is waiting on its own interactive claim.
            // Deliver on success only; whichever result consumes the request
            // first detaches the other, and delivery follows the latest rebound
            // row through PlaybackRequestCoordinator.
            if (prefetchId == strongSelf->_prefetchRequestId) {
                [strongSelf clearPrefetchOnQueue];
            }
            if (file && file.length > 0) {
                [strongSelf finishPlayOnQueueWithFile:file error:error
                                        openRequestId:request.identifier];
            }
            return;
        }
        if (prefetchId != strongSelf->_prefetchRequestId) {
            return; // a newer prefetch target, or an adoption, superseded this open
        }
        if (file && file.length > 0) {
            strongSelf->_prefetchedFile = file;
            // Use the current same-path row if prefetch was rebound while the
            // claim was open, for the same identity reason as the private open.
            AudioTrack *currentTrack = strongSelf->_prefetchedTrack;
            if (currentTrack) {
                [strongSelf maybeOpenGaplessFileForTrack:currentTrack prefetchedFile:file];
            }
        }
        else {
            // The open failed. Release the claim so that a play of this track
            // runs its own open and reports the error the usual way.
            [strongSelf clearPrefetchOnQueue];
        }
    }];
    [self resolvePrefetchRequestOnQueue];
}

@end
