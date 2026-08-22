//
//  AudioPlayer+Devices.m
//  Vibe
//
//  See AudioPlayer+Devices.h. The shared ivars and queue-side helpers come
//  from AudioPlayerInternal.h.
//

#import "AudioPlayer+Devices.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <AudioToolbox/AudioToolbox.h>

static const NSTimeInterval kSystemOutputBindRetryDelay = 2.0;

@interface AudioPlayer (DeviceQueueMutation)
// The checked mutation shared by explicit selection, automatic fallback and
// deferred launch binding. Runs on _queue.
- (BOOL)setOutputDeviceOnQueue:(NSInteger)outputDeviceID;
- (void)scheduleSystemOutputBindRetryOnQueue;
@end

#pragma mark - Output devices (internal surface + device-change observing)

@implementation AudioPlayer (DevicesInternal)

- (void)systemDefaultOutputDeviceDidChange {
    dispatch_async(_queue, ^{
        if (self.currentlyRequestedAudioDeviceId == -1) {
            [self setOutputDeviceOnQueue:-1];
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
    });
}

// Covers the explicitly chosen device disappearing while playback is idle.
// handleEngineConfigurationChange sees only removals that kill the running
// graph. setOutputDevice:-1 rebinds, and the delegate persists the fallback,
// so System Output stays the choice even after the device returns.
- (void)audioOutputDevicesDidChange {
    dispatch_async(_queue, ^{
        // knowsOutputDeviceIsAbsent:, never outputDeviceForId: — this decision
        // persists System Output, so it must not fire on the empty list a
        // still-unpublished or retrying snapshot answers with.
        NSInteger requested = self.currentlyRequestedAudioDeviceId;
        if ([[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:requested]) {
            LogInfo(@"AudioPlayer: requested output device removed; falling back to system default");
            [self setOutputDeviceOnQueue:-1];
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
    });
}

// Where a deferred launch bind may land. Stopped always, and Loading only
// while the engine is not running — which is the case that matters: launching
// by double-clicking a file starts an open within milliseconds of the async
// init, so a Stopped-only rule lets the FIRST track play through the system
// default and moves to the saved device only at the next track boundary. At
// launch nothing is rendering, so configureOutputDeviceOnQueue: rebinds with
// shouldRestore == NO and the in-flight open starts itself on the new device.
//
// TRAP: an ordinary mid-session track change is ALSO Loading, with the
// outgoing node still fading out on a running engine. Rebinding there stops
// the engine under that fade and clicks, which is why the engine check is
// part of the rule rather than a comment about launch. Playing and Paused stay
// excluded outright: a failed bind there tears down live playback.
static BOOL VibeCanBindSavedOutputDevice(VibePlayerState state, BOOL engineRunning) {
    if (state == VibePlayerStateStopped) {
        return YES;
    }
    return state == VibePlayerStateLoading && !engineRunning;
}

- (void)resolvePendingSavedOutputDeviceOnQueue {
    NSString *savedUID = _pendingSavedDeviceUID;
    NSString *savedName = _pendingSavedDeviceName;
    // Launch discovery is opportunistic, not a live device switch. If playback
    // won the race with HAL setup, leave the saved intent pending; the next
    // idle transition or device/default refresh can try again.
    if ((savedUID.length == 0 && savedName.length == 0)
            || !VibeCanBindSavedOutputDevice(_state, _engine.isRunning)
            || _pendingSavedDeviceLookupInFlight) {
        return;
    }
    _pendingSavedDeviceLookupInFlight = YES;
    __weak AudioPlayer *weakSelf = self;
    [[AudioDeviceManager sharedInstance] resolveOutputDeviceForUID:savedUID
            name:savedName completion:^(AudioDevice *device) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf->_queue, ^{
            // Keep this true through setOutputDeviceOnQueue:. Its failure can
            // publish Stopped synchronously, and that stopped-state hook must
            // not turn one failed HAL bind into an immediate retry loop.
            // A user selection queued after this lookup began owns the intent
            // and clears these fields. It must never be overwritten by a late
            // launch-time answer.
            if (![strongSelf->_pendingSavedDeviceUID isEqualToString:savedUID]
                    || ![strongSelf->_pendingSavedDeviceName isEqualToString:savedName]
                    || !device
                    || !VibeCanBindSavedOutputDevice(strongSelf->_state,
                                                     strongSelf->_engine.isRunning)) {
                strongSelf->_pendingSavedDeviceLookupInFlight = NO;
                return;
            }
            if ([strongSelf setOutputDeviceOnQueue:device.deviceId]) {
                strongSelf->_pendingSavedDeviceUID = nil;
                strongSelf->_pendingSavedDeviceName = nil;
            }
            strongSelf->_pendingSavedDeviceLookupInFlight = NO;
        });
    }];
}

- (AudioDeviceID)activeOutputDeviceID {
    AudioUnit outputUnit = _engine.outputNode.audioUnit;
    if (outputUnit) {
        AudioDeviceID deviceID = kAudioObjectUnknown;
        UInt32 size = sizeof(deviceID);
        if (AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, &size) == noErr && deviceID != kAudioObjectUnknown) {
            return deviceID;
        }
    }
    return [CoreAudioUtil systemDefaultOutputDeviceID];
}

- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID {
#if DEBUG
    // --no-audio-hw manual rendering: there is no output unit and no device
    // to bind. Report success so device selection keeps its menu and
    // persistence behavior without tripping the failure paths.
    if (_engine.isInManualRenderingMode) {
        return YES;
    }
#endif
    AudioUnit outputUnit = _engine.outputNode.audioUnit;
    if (!outputUnit) {
        LogError(@"AudioPlayer: output unit unavailable");
        return NO;
    }
    OSStatus status = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
    if (status != noErr) {
        LogError(@"AudioPlayer: could not set output device %u (OSStatus %d)", deviceID, (int)status);
        return NO;
    }
    return YES;
}

// Rebinds the engine to a new output device, restoring the current track, the
// position and the play or pause state. On failure it reports a delegate error
// and returns NO.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState priorState = _state;
    os_unfair_lock_unlock(&_stateLock);
    AudioTrack *trackToRestore = self.currentTrack;
    NSTimeInterval positionToRestore = self.position;
    // Only a live track is restored onto the new device. A finished, Stopped
    // track still carries currentTrack and _file, so rescheduling it from the
    // saved frame would resurrect it as Paused. A Loading track's open is in
    // flight and will start itself on the new device. Both leave the state
    // untouched here.
    BOOL shouldRestore = (priorState == VibePlayerStatePlaying || priorState == VibePlayerStatePaused) && trackToRestore != nil;
    BOOL wasPlaying = (priorState == VibePlayerStatePlaying);

    _segmentGeneration++;
    [self preemptRampsOnQueue];
    [self setGaplessQueuedOnQueue:NO]; // the queued segment dies with the old node

    // Unpublish the node before detaching it. The position getter uses its
    // snapshot of _node off the lock on the main thread, and calling into a
    // detached node raises.
    os_unfair_lock_lock(&_stateLock);
    AVAudioPlayerNode *oldNode = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    [oldNode stop];
    [_engine stop];
    // The state still says Playing so it can be restored below, but no node is
    // published and the engine is stopped. Drop the display/FFT activity now,
    // before a potentially slow HAL rebind, rather than waiting for the final
    // restored state.
    [self refreshOutputAudioActiveOnQueue];
    if (oldNode) {
        [_engine detachNode:oldNode];
    }

    if (![self setOutputUnitDevice:deviceID]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not switch audio output device", nil)];
        return NO;
    }

    if (shouldRestore) {
        // Reuse the already-open handle rather than reopening the URL. A
        // synchronous, timeout-free initForReading: here would wedge the whole
        // queue if the track had been evicted to an iCloud or Dropbox
        // placeholder, or sat on a hung mount, between the play and the device
        // switch. processingFormat is fixed at open, so rescheduling the
        // existing file on the new node is safe.
        AVAudioFile *file = _file; // safe: _file is only written on _queue, and we are on it
        if (!file) {
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorFileOpenFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        AVAudioPlayerNode *node = [self attachConnectedNodeForFormat:file.processingFormat];
        if (!node) {
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        double sampleRate = file.processingFormat.sampleRate;
        AVAudioFramePosition startFrame = VibeClampedStartFrame(positionToRestore, sampleRate, file.length);
        [self scheduleFile:file onNode:node fromFrame:startFrame];
        // Preserve the pause-fade guarantee. A Paused track sits at volume 0
        // so that the next resume ramps it back up; see seekToPosition:.
        // Restoring at 1.0 would make that resume start instantly at full
        // volume mid-waveform, exactly the click the fade ramp exists to
        // prevent.
        node.volume = wasPlaying ? 1.0 : 0;
        [self publishPlaybackState:(wasPlaying ? VibePlayerStatePlaying : VibePlayerStatePaused)
                              node:node file:file segmentStart:startFrame position:positionToRestore];
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                [self abandonNodeAfterFailedStart:node];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not restart playback on the new audio device", startError)];
                return NO;
            }
        }
        [self maybeArmGaplessOnQueue]; // re-queue the splice behind the restored segment
    }

    return YES;
}

// Runs on _queue when the last output device vanished mid-play. A dead engine
// must not sit behind a Playing state, which would freeze the position with no
// explanation, so park as Paused at the last valid position. That is
// restorable when a device returns, because setOutputDevice:-1 rebuilds the
// graph at this position. It is a no-op unless Playing: Paused and Loading
// report their own failure on the next start attempt. There are no generation
// bumps, because nothing is stopped or rescheduled, just as when a normal
// pause lands.
- (void)parkPlaybackForMissingOutputDeviceOnQueue {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    os_unfair_lock_unlock(&_stateLock);
    if (state != VibePlayerStatePlaying) {
        return;
    }
    NSTimeInterval position = self.position; // the engine is dead, so this serves the last valid reading
    [self publishPlaybackState:VibePlayerStatePaused node:_node file:_file
                  segmentStart:_segmentStartFrame position:position];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

// Handles AVAudioEngineConfigurationChangeNotification: the output hardware
// changed under the engine, through a device removal or a format or
// sample-rate change, which makes the engine stop itself. The health check is
// idempotent and rebuilds only when the graph actually died, so notifications
// caused by our own completed rebuilds are no-ops rather than redundant
// rebuilds.
- (void)handleEngineConfigurationChange {
    // This notification comes from AVAudioEngine, not the device manager, so
    // unlike audioOutputDevicesDidChange it can land before the first snapshot
    // is published or while one is being retried. knowsOutputDeviceIsAbsent:
    // is what keeps that from reading as removal and persisting System Output
    // over a device that is still there; a merely-unpublished list falls
    // through to the graph rebuild below, which is the right answer anyway.
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    BOOL hasNode = (_node != nil);
    os_unfair_lock_unlock(&_stateLock);
    BOOL graphHealthy = _engine.isRunning && hasNode;
    if (!graphHealthy) {
        // Publish the stopped graph before any recovery branch can wait or
        // return. Transport state intentionally remains unchanged so a
        // successful rebuild can resume it.
        [self refreshOutputAudioActiveOnQueue];
    }
    if ([[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:requested]) {
        LogError(@"Audio output device failed; falling back to system default");
        [self setOutputDeviceOnQueue:-1];
        return;
    }
    if (state == VibePlayerStateStopped) {
        return;
    }
    if (graphHealthy) {
        // The graph survived, so there is nothing to recover.
        return;
    }
    // The engine stopped itself in response to the change. Rebuild the graph,
    // preserving the track, the position and the play or pause state.
    AudioDeviceID deviceID = kAudioObjectUnknown;
    if (requested >= 0) {
        deviceID = (AudioDeviceID)requested;
    }
    else if (![CoreAudioUtil readSystemDefaultOutputDeviceID:&deviceID]) {
        // A failed property read is not proof that every output vanished. The
        // coalesced retry below gives CoreAudio one later recovery edge; do not
        // park a potentially intact track on an unknown verdict.
        LogWarn(@"AudioPlayer: could not read system default during engine recovery");
        [self scheduleSystemOutputBindRetryOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not read the system output device", nil)];
        return;
    }
    if (deviceID == kAudioObjectUnknown) {
        // No output device exists at all, because the last one vanished. Park
        // the track as Paused, restorable when a device returns — see
        // parkPlaybackForMissingOutputDeviceOnQueue — and say why.
        if (state == VibePlayerStatePlaying) {
            [self parkPlaybackForMissingOutputDeviceOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"No audio output device is available", nil)];
        }
        return;
    }
    // Idempotence while paused. A Paused rebuild deliberately leaves the
    // engine stopped, so the isRunning check above cannot attest to graph
    // health for it, and without this every notification while paused re-ran a
    // full rebuild. A node present and the right device bound means the graph
    // is intact, and the resume starts the engine, just as after a normal idle
    // stop.
    if (state == VibePlayerStatePaused && hasNode && [self activeOutputDeviceID] == deviceID) {
        return;
    }
    [self configureOutputDeviceOnQueue:deviceID];
}

@end

#pragma mark - Output devices (queue-side mutation, declared at the top of this file)

@implementation AudioPlayer (DeviceQueueMutation)

- (void)scheduleSystemOutputBindRetryOnQueue {
    if (_systemOutputBindRetryScheduled) {
        return;
    }
    _systemOutputBindRetryScheduled = YES;
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kSystemOutputBindRetryDelay * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // Keep the guard set through the call. A second read failure must wait
        // for a real device/default notification rather than polling forever.
        if (strongSelf.currentlyRequestedAudioDeviceId == -1) {
            [strongSelf setOutputDeviceOnQueue:-1];
        }
        strongSelf->_systemOutputBindRetryScheduled = NO;
    });
}

- (BOOL)setOutputDeviceOnQueue:(NSInteger)outputDeviceID {

    LogDebug(@"setOutputDevice: %@", @(outputDeviceID));

    AudioDeviceID newDeviceID = kAudioObjectUnknown;
    if (outputDeviceID >= 0) {
        newDeviceID = (AudioDeviceID)outputDeviceID;
    }
    else if (![CoreAudioUtil readSystemDefaultOutputDeviceID:&newDeviceID]) {
        // Following System Output is still the durable policy, but a transient
        // property-read failure says nothing about whether hardware exists. Do
        // not tear down or park a graph on that unknown verdict.
        LogWarn(@"AudioPlayer: could not read the system default output device");
        self.currentlyRequestedAudioDeviceId = -1;
        [self notifyRequestedOutputDeviceOnQueue];
        [self scheduleSystemOutputBindRetryOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not read the system output device", nil)];
        return NO;
    }

    if (newDeviceID == kAudioObjectUnknown) {
        // The default read succeeded and answered "none": no output device
        // exists at all. Only the -1 path can land here — every concrete id
        // is a real enumerated device — so following System Output remains
        // the honest committed choice while nothing exists to bind.
        LogError(@"AudioPlayer: no output device exists to fall back to");
        [self parkPlaybackForMissingOutputDeviceOnQueue];
        self.currentlyRequestedAudioDeviceId = outputDeviceID;
        [self notifyRequestedOutputDeviceOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Audio output device is unavailable", nil)];
        return NO;
    }

    AudioDeviceID currentDeviceID = [self activeOutputDeviceID];

    LogDebug(@"current: %@ new: %@", @(currentDeviceID), @(newDeviceID));

    if (newDeviceID != currentDeviceID) {
        if (![self configureOutputDeviceOnQueue:newDeviceID]) {
            // configureOutputDeviceOnQueue has already reported the error.
            // Do not record or persist a device we failed to switch to.
            return NO;
        }
    }
    else if (outputDeviceID >= 0) {
        // The chosen device is already the active one, but "active" may mean
        // only that the output unit is tracking the system default and was
        // never explicitly bound. Pin it before committing the requested ID.
        if (![self setOutputUnitDevice:newDeviceID]) {
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"Could not switch audio output device", nil)];
            return NO;
        }
    }

    self.currentlyRequestedAudioDeviceId = outputDeviceID;
    [self notifyRequestedOutputDeviceOnQueue];
    return YES;
}

// The single announcement of the committed choice, sent on EVERY settled
// mutation rather than only when the id moved. The delegate both persists it
// and drives the menu checkmark, and it is idempotent, so re-sending an
// unchanged value costs a defaults write nobody notices. Suppressing it made
// "Settings names the last committed device" a guarantee with no enforcement:
// any path that left the two disagreeing — a failed bind, a launch preference
// resolved to the id already requested — could then never resynchronize them,
// because the one call that writes Settings was skipped precisely when they
// already looked equal. Runs on _queue; the delegate hop is to main.
- (void)notifyRequestedOutputDeviceOnQueue {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    run_on_main_thread({
        [self.delegate audioPlayer:self didChangeOutputDevice:requested];
    });
}

@end

#pragma mark - Output devices (public API, declared in AudioPlayer.h)

@implementation AudioPlayer (Devices)

- (NSInteger)currentlyActiveAudioDeviceId {
    return (NSInteger)[self activeOutputDeviceID];
}

- (void)setOutputDevice:(NSInteger)outputDeviceID {
    dispatch_async(_queue, ^{
        // System Output is a policy intent, so it supersedes a saved concrete
        // device even when no output currently exists. Clear before binding to
        // fence a resolver completion already queued behind this selection.
        if (outputDeviceID == -1) {
            self->_pendingSavedDeviceUID = nil;
            self->_pendingSavedDeviceName = nil;
        }

        BOOL didBind = [self setOutputDeviceOnQueue:outputDeviceID];
        if (didBind && outputDeviceID >= 0) {
            // A concrete choice owns the intent only once the HAL accepted it.
            // On failure, Settings still names the saved launch preference, so
            // keep the in-memory pending intent aligned with it.
            self->_pendingSavedDeviceUID = nil;
            self->_pendingSavedDeviceName = nil;
        }
        // Persistence itself is setOutputDeviceOnQueue:'s, which announces every
        // committed outcome — the two -1 failures that still commit the policy
        // (a HAL read failure, and no output device existing at all) included.
        // A failed graph reconfiguration is the one case that commits nothing:
        // the engine did not move, so neither the requested id nor Settings may
        // claim it did.
    });
}

@end
