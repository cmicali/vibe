//
//  AudioPlayer+Recovery.m
//  Vibe (iOS)
//
//  See AudioPlayer+Recovery.h. The shared ivars and queue-side helpers come
//  from AudioPlayerInternal.h.
//

#import "AudioPlayer+Recovery.h"
#import "AudioPlayerInternal.h"
#import "PlaybackDeliveryRules.h"

@implementation AudioPlayer (Recovery)

// A route at the pipeline's rate is a restart: the voice's ring and gain
// survived the stop, so nothing is rescheduled. A route at another rate is
// followed — the source node and the bus rebuilt at it, the track kept —
// so the bus converts once, at the route's rate, and the output node
// converts nothing; the follow restarts a playing output itself. The same
// follow runs before every engine start (a resume, a play's settlement),
// because a route loss or an interruption can leave this recovery
// unanswered and the next start would otherwise run on the stale rate.
- (void)recoverFromEngineConfigurationChange {
    dispatch_async(_queue, ^{
        BOOL engineRunning = self->_engine.isRunning;
        if (!engineRunning) {
            // The notification arrives after the graph has already stopped.
            // Publish that edge before any state-specific recovery can return
            // or wait; a quick successful restart coalesces active on main.
            [self refreshOutputAudioActiveOnQueue];
            [self updateDrainTimerOnQueue];
        }
        double routeRate = [self->_engine.outputNode outputFormatForBus:0].sampleRate;
        if (routeRate > 0 && routeRate != [self masterBusFormatOnQueue].sampleRate) {
            [self followOutputRouteOnQueue];
            return;
        }
        if (self->_state != VibePlayerStatePlaying || !self->_voice || engineRunning) {
            return; // idle, Loading, or the engine survived the change
        }
        NSError *startError = nil;
        if (![self startOutputOnQueue:&startError]) {
            // No output to restart on. Park Paused at the same position, so
            // the next resume restarts the engine, and say why.
            LogError(@"AudioPlayer: config-change restart failed (%@)", startError);
            [self pauseCurrentVoiceOnQueue];
            return;
        }
        [self armSignalProbeOnQueue:@"configuration change"];
    });
}

// Dead objects are dropped, never stopped or detached — messaging the defunct
// engine's graph is what must not happen here, which is
// dropEngineBoundStateOnQueue's contract — and createOutputOnQueue
// rebuilds exactly what init built: fresh FX nodes with the recorded intent
// re-applied (or the bare mixer -> output wire), and the debug argv modes. The
// source segment rebuilds itself at the next settlement.
- (void)beginMediaServicesResetWithCompletion:
        (VibeMediaServicesResetCompletion)completion {
    // TRAP: playTrack: mints its identifier and enqueues its work under this
    // same lock. Keeping the reset enqueue inside the critical section makes
    // the queue order agree with notification-receipt order, including a play
    // submitted from main before its reset handler gets there.
    os_unfair_lock_lock(&_stateLock);
    uint64_t capturedNewestSubmittedPlayIdentifier =
            _nextSubmittedPlayIdentifier;
    dispatch_async(_queue, ^{
        LogWarn(@"AudioPlayer: rebuilding engine after media services reset");
        AudioTrack *resetTrack = self.currentTrack;
        // The voice's consumed frames, read before the bus is dropped; 0 for
        // a Stopped player, so a later replay of a finished track begins at
        // zero as it always did.
        NSTimeInterval position = self.position;
        if (!resetTrack) {
            os_unfair_lock_lock(&self->_stateLock);
            resetTrack = self.loadingTrack ?: self.lastSubmittedPlayTrack;
            os_unfair_lock_unlock(&self->_stateLock);
        }
        [self dropEngineBoundStateOnQueue];
        self->_activeSubmittedPlayIdentifier = 0;
        self.currentTrack = nil;
        [self publishState:VibePlayerStateStopped voice:0 file:nil startSeconds:0 baseFrames:0];
        [self createOutputOnQueue];
        if (!completion) {
            return;
        }
        run_on_main_thread({
            os_unfair_lock_lock(&self->_stateLock);
            uint64_t newestSubmittedPlayIdentifier =
                    self->_nextSubmittedPlayIdentifier;
            os_unfair_lock_unlock(&self->_stateLock);
            if (!VibePlaybackSubmissionStateIsUnchanged(
                    capturedNewestSubmittedPlayIdentifier,
                    newestSubmittedPlayIdentifier)) {
                return;
            }
            completion(resetTrack, position);
        });
    });
    os_unfair_lock_unlock(&_stateLock);
}

@end
