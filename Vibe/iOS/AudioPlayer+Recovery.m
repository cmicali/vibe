//
//  AudioPlayer+Recovery.m
//  Vibe (iOS)
//
//  See AudioPlayer+Recovery.h. The shared ivars and queue-side helpers come
//  from AudioPlayerInternal.h.
//

#import "AudioPlayer+Recovery.h"
#import "AudioPlayerInternal.h"

@implementation AudioPlayer (Recovery)

// The in-place restart is the same ballet as the paused idle stop's
// reschedule: [node stop] fires the old segment's completion, so _generation
// bumps first; scheduling needs no running engine; and
// startEngineAndPlayNode: restarts it. The output node converts if the new
// route runs at a different sample rate from the wired format, so no
// reconnection is needed (see AudioFX's wiring note).
- (void)recoverFromEngineConfigurationChange {
    dispatch_async(_queue, ^{
        if (self->_state != VibePlayerStatePlaying || self->_pausePending) {
            // Paused and stopped recover lazily on the next start, and a
            // pending pause owns the transport: its completion pauses in
            // place, engine running or not.
            return;
        }
        AVAudioPlayerNode *node = self->_node;
        AVAudioFile *file = self->_file;
        if (!node || !file || self->_engine.isRunning) {
            return; // Loading, or the engine survived the change.
        }
        // The getter serves the last-valid cache here: lastRenderTime went
        // nil when the engine stopped itself.
        NSTimeInterval position = self.position;
        self->_generation++; // the [node stop] below fires the old segment's completion
        uint64_t rampGen = [self preemptRampsOnQueue];
        [node stop];
        double sampleRate = file.processingFormat.sampleRate;
        AVAudioFramePosition startFrame = VibeClampedStartFrame(position, sampleRate, file.length);
        [self scheduleFile:file onNode:node fromFrame:startFrame];
        NSError *startError = nil;
        if (![self startEngineAndPlayNode:node error:&startError]) {
            // No output to restart on. Park Paused at the same position, so
            // the next resume restarts the engine, and say why.
            LogError(@"AudioPlayer: config-change restart failed (%@)", startError);
            [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                          segmentStart:startFrame position:position];
            [self scheduleEngineIdleStopOnQueue];
            AudioTrack *track = self.currentTrack;
            run_on_main_thread({
                [self.delegate audioPlayer:self didPausePlaying:track];
            });
            return;
        }
        [self publishPlaybackState:VibePlayerStatePlaying node:node file:file
                      segmentStart:startFrame position:position];
        [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
    });
}

// Dead objects are dropped, never stopped or detached — messaging the defunct
// engine's graph is what must not happen here, which is
// dropEngineBoundStateOnQueue's contract — and installMasterBusOnQueue mints
// fresh FX nodes and re-applies the recorded intent (or, with FX disabled,
// rewires the bare mixer -> output bus), so the rebuilt graph comes up with
// the same effect state.
- (void)reinitializeAfterMediaServicesReset {
    dispatch_async(_queue, ^{
        LogWarn(@"AudioPlayer: rebuilding engine after media services reset");
        self->_generation++;
        [self preemptRampsOnQueue];
        [self dropEngineBoundStateOnQueue];
        self.currentTrack = nil;
        [self publishPlaybackState:VibePlayerStateStopped node:nil file:nil segmentStart:0 position:0];
        self->_engine = [[AVAudioEngine alloc] init];
        [self installMasterBusOnQueue];
    });
}

@end
