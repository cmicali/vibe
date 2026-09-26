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

@implementation AudioPlayer (Carrier)

- (NSArray<NSDictionary<NSString *, id> *> *)carrierAudioPathOnQueue {
    NSMutableDictionary *output = [NSMutableDictionary dictionary];
    output[@"carrier"] = @"outputUnit";
    output[@"routeSampleRate"] = @(AVAudioSession.sharedInstance.sampleRate);
    if (_outputUnit) {
        output[@"unitSampleRate"] = @(_outputUnit.format.sampleRate);
        output[@"unitRunning"] = @(_outputUnit.running);
        [output addEntriesFromDictionary:[self carrierCountersOnQueue]];
        output[@"presentationLatency"] = @(_outputUnit.presentationLatency);
        output[@"bufferLatency"] = @(_outputUnit.bufferLatency);
    }
    return @[output];
}

// The pipeline takes the route's rate now; the unit is made at the first
// start, after the play has activated the session. Reading the session's
// rate claims nothing, and no audio object exists before a play asks for
// one, so a cold launch cannot stop another app's audio.
- (void)createCarrierOnQueue {
    double rate = AVAudioSession.sharedInstance.sampleRate;
    [self setMasterBusFormatOnQueue:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate > 0 ? rate : 44100 channels:2]];
}

- (BOOL)startCarrierOnQueueWithError:(NSError **)error {
    if (!_outputUnit) {
        AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
        if (!unit) {
            if (error) *error = VibeAudioError(VibeAudioErrorEngineStartFailed, @"No audio output is available", nil);
            return NO;
        }
        [self attachOutputUnitOnQueue:unit];
        [unit configureFormat:_masterFormat renderProc:VibeMasterBusRender refCon:_masterBus];
    }
    [_outputUnit start]; // a refusal arrives later, at outputUnitRefusedStartOnQueue:
    return YES;
}

- (void)releaseIdleCarrierOnQueue {}

// Stopped, as every caller has it. Before the first start there is no unit,
// and the next start makes one at the format set here.
- (BOOL)adoptCarrierFormatOnQueue:(AVAudioFormat *)format {
    [_outputUnit configureFormat:format renderProc:VibeMasterBusRender refCon:_masterBus];
    [self setMasterBusFormatOnQueue:format];
    return YES;
}

// RemoteIO converts a client format the hardware does not run at, so a
// pipeline left at the old rate would still play — resampled a second time.
// Following the session's rate keeps the one conversion the bus's. The
// debug pump has no route, and keeps the rate it was made at.
- (BOOL)followOutputRouteOnQueue {
    double rate = AVAudioSession.sharedInstance.sampleRate;
    if (![self drivesOutputDeviceOnQueue] || rate <= 0 || !_masterFormat || rate == _masterFormat.sampleRate) {
        return YES;
    }
    return [self followOutputFormatOnQueue:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2]];
}

@end

@implementation AudioPlayer (Recovery)

// A rate follow restarts a playing output itself. Otherwise the one thing to
// recover is a unit the system stopped under a playing voice — an
// interruption whose resume raced the pause — which restarts in place: the
// voice's ring and gain survived the stop, so nothing is rescheduled.
- (void)recoverOutput {
    dispatch_async(_queue, ^{
        if (![self carrierRunningOnQueue]) {
            // Publish that edge before anything below returns or waits; a
            // quick successful restart coalesces active on main.
            [self refreshOutputAudioActiveOnQueue];
            [self updateDrainTimerOnQueue];
        }
        if (![self followOutputRouteOnQueue]) {
            return; // the follow reset or parked the player and said why
        }
        if (self->_state != VibePlayerStatePlaying || !self->_voice || [self carrierRunningOnQueue]) {
            return; // idle, Loading, or the output is running
        }
        NSError *startError = nil;
        if (![self startOutputOnQueue:&startError]) {
            // No output to restart on. Park Paused at the same position, so
            // the next resume starts it, and say why.
            LogError(@"AudioPlayer: output recovery failed (%@)", startError);
            [self pauseCurrentVoiceOnQueue];
            return;
        }
        [self armSignalProbeOnQueue:@"output recovery"];
    });
}

// Dead objects are dropped, never stopped — messaging the defunct unit is
// what must not happen here, which is dropOutputBoundStateOnQueue's
// contract — and createOutputOnQueue rebuilds exactly what init built: the
// pipeline at the route's rate, its unit made at the next start, or the
// shared debug pump. The source segment rebuilds itself at the next
// settlement.
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
        LogWarn(@"AudioPlayer: rebuilding the output after media services reset");
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
        [self dropOutputBoundStateOnQueue];
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
