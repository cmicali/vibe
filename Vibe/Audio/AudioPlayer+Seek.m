//
//  AudioPlayer+Seek.m
//  Vibe
//

#import "AudioPlayer+Seek.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "FadeMath.h"
#import "PlaybackRequestCoordinator.h"

@implementation AudioPlayer (Seek)

- (void)seekToPosition:(NSTimeInterval)pos {
    [self seekToPosition:pos restoringPreemptedPause:NO];
}

- (void)seekToPosition:(NSTimeInterval)pos
        restoringPreemptedPause:(BOOL)restoringPreemptedPause {
    // The caller computed pos against the track that is current NOW — a
    // scrubber fraction of its duration, a bar skip from its tempo. A gapless
    // boundary can promote the next track before the block below runs, and
    // applying the stale target to the promoted file would jump it to a
    // meaningless spot (or clamp to its last frame and end it). Snapshot the
    // intent and drop the seek if the track moved on.
    AudioTrack *intendedTrack = self.currentTrack;
    uint64_t intendedSubmittedPlayIdentifier = 0;
    os_unfair_lock_lock(&_stateLock);
    if (_state == VibePlayerStateLoading) {
        intendedTrack = self.loadingTrack;
        intendedSubmittedPlayIdentifier = self.loadingSubmittedPlayIdentifier;
    }
    else if (self.lastSubmittedPlayTrack) {
        // A play is queued but has not reached the player queue yet, so
        // currentTrack still names the outgoing track. Aim at the play the
        // user just started — the row they are looking at — rather than at the
        // one it is replacing.
        intendedTrack = self.lastSubmittedPlayTrack;
        intendedSubmittedPlayIdentifier = self.lastSubmittedPlayIdentifier;
    }
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        AudioTrack *track = self.currentTrack;
        if (self->_state == VibePlayerStateLoading) {
            VibePlaybackRequest *request = self.pendingRequest.currentRequest;
            track = request.track;
            [self.pendingRequest seekToPosition:pos
                                 ifCurrentTrackIs:intendedTrack
                         submittedPlayIdentifier:intendedSubmittedPlayIdentifier];
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }
        if (track != intendedTrack) {
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }
        AVAudioPlayerNode *node = self->_node;
        AVAudioFile *file = self->_file;
        if (!node || !file) {
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }
        uint64_t owningSubmittedPlayIdentifier =
                self->_activeSubmittedPlayIdentifier;
        double sampleRate = file.processingFormat.sampleRate;
        BOOL wasPlaying = (self->_state == VibePlayerStatePlaying);
        AVAudioFramePosition startFrame = VibeClampedStartFrame(pos, sampleRate, file.length);
        NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;
        self->_segmentGeneration++; // drop the current segment's stop-fired completion

        if (!wasPlaying) {
            // Paused: reschedule the existing, silent node in place. No audio
            // is rendering, so there is nothing to declick, and the next
            // resume fades in from the seeked frame. The faded volume is kept,
            // and the resume ramps it back up.
            [self preemptRampsOnQueue];
            [self setGaplessQueuedOnQueue:NO]; // the stop drops the queued segment
            [node stop];
            [self scheduleFile:file onNode:node fromFrame:startFrame];
            [self publishPlaybackState:self->_state node:node file:file segmentStart:startFrame position:framePosition];
            [self maybeArmGaplessOnQueue];
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }

        // Playing: declick without touching the audio graph. Reconnecting a
        // live node, as the two-node crossfade's reroute does, is itself a
        // click on a running engine. So instead fade this node down,
        // reschedule it in place and fade it back up: both the [node stop] and
        // the new segment's start then land at silence. The reschedule is
        // deferred into the fade-out completion, because the node must stay
        // audible through the ramp, and the position state is rewritten there
        // so that the getter follows the node.
        //
        // A user seek deliberately cancels a pending pause; the internal
        // splice-unschedule seek must not — the user pressed pause during a
        // playlist retarget they never see, so the preempt below would
        // silently drop their pause and fade back up. Capture the intent
        // before the preempt clears it; finishSeekOnQueue lands parked.
        BOOL reissuePause = restoringPreemptedPause && self->_pausePending;
        uint64_t rampGen = [self preemptRampsOnQueue];
        __weak AudioPlayer *weakSelf = self;
        [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
            [weakSelf finishSeekOnQueue:node
                                   file:file
                             startFrame:startFrame
                          framePosition:framePosition
                         rampGeneration:rampGen
                                  track:track
                submittedPlayIdentifier:owningSubmittedPlayIdentifier
                           reissuePause:reissuePause];
        }];
    });
}

// A restart failure outranks whichever ramp preempted this seek. Cancel that
// ramp, keep the newly scheduled frame parked, and expose Paused rather than a
// Playing state backed by a stopped node. A newer seek's cancelled completion
// still runs and can park its newer frame before it settles.
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

// The playing seek's fade-out completion; the parameters are what
// seekToPosition: captured when the seek was requested. Four outcomes, each
// with an early return: the node was replaced, the fade was preempted, the
// engine failed to start, or the reschedule lands and fades back in. Every
// path delivers didFinishSeeking:.
- (void)finishSeekOnQueue:(AVAudioPlayerNode *)node
                     file:(AVAudioFile *)file
               startFrame:(AVAudioFramePosition)startFrame
            framePosition:(NSTimeInterval)framePosition
           rampGeneration:(uint64_t)rampGen
                    track:(AudioTrack *)track
  submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier
             reissuePause:(BOOL)reissuePause {
    if (_node != node || _file != file) {
        // A new play, track change, stop or device switch replaced the
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
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    // Same node, but a pause, its cancel or a newer seek bumped the ramp
    // generation mid-fade. The reschedule below still lands, since the
    // user asked for this position, but the preemptor owns volume and
    // _state, so this path touches neither.
    BOOL preempted = (rampGen != _rampGeneration);
    // [node stop] fires the completion of whatever segment is scheduled
    // right now, which after a preempted seek's own reschedule can carry
    // the current generation rather than the one this seek's entry bump
    // retired. Re-bump immediately before the stop, or that completion
    // reads as current and "finishes" the track.
    _segmentGeneration++;
    [self setGaplessQueuedOnQueue:NO]; // the stop drops the queued segment
    [node stop];
    [self scheduleFile:file onNode:node fromFrame:startFrame];
    [self maybeArmGaplessOnQueue]; // re-queue the splice behind the new segment
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
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    if (reissuePause) {
        // The pause this internal seek preempted still owns the outcome: land
        // the reschedule parked, as the completed pause fade would have. The
        // stopped node holds the new segment, so resume plays it from here —
        // the paused-seek shape, plus the pause's own delegate settlement.
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
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
    uint64_t fadeInGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:0 to:1.0 generation:fadeInGen completion:nil];
    run_on_main_thread({
        [self.delegate audioPlayer:self didFinishSeeking:track];
    });
}

@end
