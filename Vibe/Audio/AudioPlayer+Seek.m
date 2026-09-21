//
//  AudioPlayer+Seek.m
//  Vibe
//

#import "AudioPlayer+Seek.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "FadeMath.h"
#import "PlaybackRequestCoordinator.h"

// A seek's own reschedule — the node stop and the file reschedule — taking
// this long is worth recording. The engine start a seek may also perform is
// attributed by +Engine's own slow-start log, not counted again here.
// Warn level so it persists and a user can retrieve it with `log show`.
static const NSTimeInterval kSlowSeekLogThresholdSeconds = 0.25;

@implementation AudioPlayer (Seek)

- (void)notifySeekFinishedOnQueue:(AudioTrack *)track reason:(NSString *)reason submittedPlay:(uint64_t)play {
#if VIBE_VERBOSE_LOGGING
    uint64_t segment = _segmentGeneration;
    uint64_t deliveredAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: seek for play %llu settled on current segment %llu: %@", play, segment, reason);
#endif
    run_on_main_thread({
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu didFinishSeeking main delivery %.1f ms, %@, current submission %d",
                play, segment, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - deliveredAt) / 1e6,
                reason, [self submittedPlayIsCurrent:play]);
#endif
        [self.delegate audioPlayer:self didFinishSeeking:track];
    });
}

- (void)seekToPosition:(NSTimeInterval)pos {
#if VIBE_VERBOSE_LOGGING
    uint64_t submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: seek submitted at %llu to %.3fs", submittedAt, pos);
#endif
    // The caller computed pos against the track that is current NOW — a
    // scrubber fraction of its duration, a bar skip from its tempo. A gapless
    // boundary can promote the next track before the block below runs, and
    // applying the stale target to the promoted file would jump it to a
    // meaningless spot (or clamp to its last frame and end it). Snapshot the
    // intent and drop the seek if the track moved on.
    AudioTrack *intendedTrack = self.currentTrack;
    uint64_t intendedSubmittedPlayIdentifier = 0;
    os_unfair_lock_lock(&_stateLock);
    uint64_t diagnosticRequestedPlay = _nextSubmittedPlayIdentifier;
    if (self.lastSubmittedPlayTrack) {
        // A play is queued but has not reached the player queue yet, so
        // currentTrack still names the outgoing track. The handoff is cleared
        // the moment its play reaches Loading, so when it is set it is
        // strictly newer than any Loading mirror — it wins even while an
        // older play's open is still in flight. Aim at the play the user just
        // started — the row they are looking at — rather than at the one it
        // is replacing.
        intendedTrack = self.lastSubmittedPlayTrack;
        intendedSubmittedPlayIdentifier = self.lastSubmittedPlayIdentifier;
    }
    else if (_state == VibePlayerStateLoading) {
        intendedTrack = self.loadingTrack;
        intendedSubmittedPlayIdentifier = self.loadingSubmittedPlayIdentifier;
    }
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu seek %llu admitted after %.1f ms, target %.3fs, state %ld",
                [self diagnosticPlayIdentifierOnQueue], self->_segmentGeneration, submittedAt,
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submittedAt) / 1e6, pos, (long)self->_state);
#endif
        AudioTrack *track = self.currentTrack;
        if (self->_state == VibePlayerStateLoading) {
            VibePlaybackRequest *request = self.pendingRequest.currentRequest;
            track = request.track;
            [self.pendingRequest seekToPosition:pos
                                 ifCurrentTrackIs:intendedTrack
                         submittedPlayIdentifier:intendedSubmittedPlayIdentifier];
            [self notifySeekFinishedOnQueue:track reason:@"loading intent" submittedPlay:diagnosticRequestedPlay];
            return;
        }
        if (track != intendedTrack) {
            [self notifySeekFinishedOnQueue:track reason:@"ignored: track changed" submittedPlay:diagnosticRequestedPlay];
            return;
        }
        [self seekOnQueueToPosition:pos restoringPreemptedPause:NO];
    });
}

- (void)seekOnQueueToPosition:(NSTimeInterval)pos
      restoringPreemptedPause:(BOOL)restoringPreemptedPause {
    AudioTrack *track = self.currentTrack;
    AVAudioPlayerNode *node = _node;
    AVAudioFile *file = _file;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    if (!node || !file) {
        [self notifySeekFinishedOnQueue:track reason:@"no playable segment" submittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    double sampleRate = file.processingFormat.sampleRate;
    BOOL wasPlaying = (_state == VibePlayerStatePlaying);
    AVAudioFramePosition startFrame = VibeClampedStartFrame(pos, sampleRate, file.length);
    NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;
    _segmentGeneration++; // drop the current segment's stop-fired completion

    if (!wasPlaying) {
        _pendingSeekPosition = -1;
        // Paused: reschedule the existing, silent node in place. No audio
        // is rendering, so there is nothing to declick, and the next
        // resume fades in from the seeked frame. The faded volume is kept,
        // and the resume ramps it back up.
        _seekRampGeneration = [self preemptRampsOnQueue];
        [self setGaplessQueuedOnQueue:NO]; // the stop drops the queued segment
        uint64_t rescheduledAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [node stop];
        [self scheduleFile:file onNode:node fromFrame:startFrame];
        NSTimeInterval rescheduleSeconds =
                (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - rescheduledAt) / NSEC_PER_SEC;
        BOOL slowSeek = rescheduleSeconds > kSlowSeekLogThresholdSeconds;
        LogTiming(slowSeek, @"AudioPlayer: %@paused seek — reschedule %.3fs "
                @"(the player queue was blocked for this long)",
                slowSeek ? @"slow " : @"", rescheduleSeconds);
        [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
        [self maybeArmGaplessOnQueue];
        [self notifySeekFinishedOnQueue:track reason:@"paused seek" submittedPlay:owningSubmittedPlayIdentifier];
        return;
    }

    // Stop and reschedule only after fading to silence; reconnecting the
    // live graph would click. Internal splice removal preserves a pending
    // pause, while a user seek cancels it.
    BOOL reissuePause = restoringPreemptedPause && _pausePending;
    uint64_t rampGen = [self preemptRampsOnQueue];
    _seekRampGeneration = rampGen;
    _pausePending = reissuePause;
    _pendingSeekPosition = framePosition;
    __weak AudioPlayer *weakSelf = self;
    [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
        [weakSelf finishSeekOnQueue:node
                               file:file
                         startFrame:startFrame
                      framePosition:framePosition
                     rampGeneration:rampGen
                              track:track
            submittedPlayIdentifier:owningSubmittedPlayIdentifier];
    }];
}

// A restart failure outranks whichever ramp preempted this seek. Cancel that
// ramp, keep the newly scheduled frame parked, and expose Paused rather than a
// Playing state backed by a stopped node.
- (void)parkSeekAfterStartFailureForNode:(AVAudioPlayerNode *)node
                                    file:(AVAudioFile *)file
                              startFrame:(AVAudioFramePosition)startFrame
                           framePosition:(NSTimeInterval)framePosition
                                   error:(NSError *)error
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_node != node || _file != file || _state != VibePlayerStatePlaying) {
        [self refreshOutputAudioActiveOnQueue];
        return;
    }
    [self preemptRampsOnQueue];
    [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                  segmentStart:startFrame position:framePosition];
    [self scheduleEngineIdleStopOnQueue];
    [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
            @"Could not resume playback after seek", error)
           forSubmittedPlay:submittedPlayIdentifier];
}

// Every fade-out completion settles didFinishSeeking:, including a superseded seek.
- (void)finishSeekOnQueue:(AVAudioPlayerNode *)node
                     file:(AVAudioFile *)file
               startFrame:(AVAudioFramePosition)startFrame
            framePosition:(NSTimeInterval)framePosition
           rampGeneration:(uint64_t)rampGen
                    track:(AudioTrack *)track
  submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_seekRampGeneration != rampGen || _node != node || _file != file) {
        // A newer seek owns the position, even if it repeats this target.
        // A play, track change, stop or device switch may also replace the
        // node while this faded. That operation owns playback and this
        // seek's target is moot. The seek is dropped, but the request
        // still settles the UI: the header promises didFinishSeeking:
        // for every seek request, and Control Center resyncs off it.
        // Same node but a different file is the gapless boundary promoting
        // mid-fade; rescheduling the captured file would resurrect the
        // finished track, so drop the seek and restore the fade's volume.
        if (_node == node && rampGen == _rampGeneration) {
            [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
        }
        [self notifySeekFinishedOnQueue:track reason:@"superseded seek" submittedPlay:submittedPlayIdentifier];
        return;
    }
    _pendingSeekPosition = -1;
    // Same node and seek, but a pause or its cancel bumped the ramp
    // generation mid-fade. The reschedule below still lands, since the
    // user asked for this position, but the preemptor owns volume and
    // _state, so this path touches neither.
    BOOL preempted = (rampGen != _rampGeneration);
    // Retire whichever segment is now scheduled before stop fires its completion.
    _segmentGeneration++;
    [self setGaplessQueuedOnQueue:NO]; // the stop drops the queued segment
    uint64_t rescheduledAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    [node stop];
    [self scheduleFile:file onNode:node fromFrame:startFrame];
    [self maybeArmGaplessOnQueue]; // re-queue the splice behind the new segment
    NSTimeInterval rescheduleSeconds =
            (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - rescheduledAt) / NSEC_PER_SEC;
    BOOL slowSeek = rescheduleSeconds > kSlowSeekLogThresholdSeconds;
    LogTiming(slowSeek, @"AudioPlayer: %@seek — reschedule %.3fs "
            @"(the player queue was blocked for this long)",
            slowSeek ? @"slow " : @"", rescheduleSeconds);
    if (preempted) {
        [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
        BOOL stillPlaying = (_state == VibePlayerStatePlaying);
        if (stillPlaying) {
            // Mid-pause-fade the state is still Playing, because the
            // pause completion has not landed and will not if it is
            // cancelled. Restart the node, so that a cancelled pause is
            // not left with a stopped node behind a Playing state. The
            // volume stays wherever the preemptor's ramp has it: that
            // ramp keeps stepping, and a completing pause finds the node
            // where completePauseOfNode: expects it.
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                [self parkSeekAfterStartFailureForNode:node
                                                  file:file
                                            startFrame:startFrame
                                         framePosition:framePosition
                                                 error:startError
                               submittedPlayIdentifier:submittedPlayIdentifier];
            }
        }
        [self notifySeekFinishedOnQueue:track reason:@"newer pause/resume owns state" submittedPlay:submittedPlayIdentifier];
        return;
    }
    if (_pausePending) {
        // The pause this internal seek preempted still owns the outcome: land
        // the reschedule parked, as the completed pause fade would have. The
        // stopped node holds the new segment, so resume plays it from here —
        // the paused-seek shape, plus the pause's own delegate settlement.
        _pausePending = NO;
        node.volume = 0; // resume ramps up from silence, as after a real pause
        [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                      segmentStart:startFrame position:framePosition];
        [self scheduleEngineIdleStopOnQueue];
        AudioTrack *pausedTrack = self.currentTrack;
        run_on_main_thread({
            [self.delegate audioPlayer:self didPausePlaying:pausedTrack];
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    node.volume = 0; // ramp back up from silence
    NSError *startError = nil;
    if (![self startEngineAndPlayNode:node error:&startError]) {
        // The rescheduled segment stays at the live generation deliberately:
        // it is parked, not superseded, and a later resume plays it out — its
        // completion must still fire the natural track end. (A bump here
        // orphans it: resume plays to the end, no didFinishPlaying:, the
        // position pinned at the duration with the state stuck Playing.)
        // Keep the seeked frame, and report paused so the UI recovers.
        [self parkSeekAfterStartFailureForNode:node
                                          file:file
                                    startFrame:startFrame
                                 framePosition:framePosition
                                         error:startError
                       submittedPlayIdentifier:submittedPlayIdentifier];
        [self notifySeekFinishedOnQueue:track reason:@"start failed, parked" submittedPlay:submittedPlayIdentifier];
        return;
    }
    [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
    uint64_t fadeInGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:0 to:1.0 generation:fadeInGen completion:nil];
    [self notifySeekFinishedOnQueue:track reason:@"completed" submittedPlay:submittedPlayIdentifier];
}

@end
