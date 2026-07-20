//
//  AudioPlayer+Devices.m
//  Vibe
//
//  See AudioPlayer+Devices.h. Moved verbatim from AudioPlayer.m; shared
//  ivars and queue-side helpers come from AudioPlayerInternal.h.
//

#import "AudioPlayer+Devices.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - Output devices (internal surface + device-change observing)

@implementation AudioPlayer (DevicesInternal)

- (void)systemDefaultOutputDeviceDidChange {
    if (self.currentlyRequestedAudioDeviceId == -1) {
        [self setOutputDevice:self.currentlyRequestedAudioDeviceId];
    }
}

// Covers the explicitly chosen device disappearing while playback is idle —
// handleEngineConfigurationChange only sees removals that kill the running
// graph. setOutputDevice:-1 rebinds and the delegate persists the fallback,
// so System Output stays the choice even after the device returns.
- (void)audioOutputDevicesDidChange {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (requested >= 0 && ![[AudioDeviceManager sharedInstance] outputDeviceForId:requested]) {
        LogInfo(@"AudioPlayer: requested output device removed; falling back to system default");
        [self setOutputDevice:-1];
    }
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

// Rebinds the engine to a new output device, restoring the current track,
// position, and play/pause state. Returns NO (after reporting a delegate
// error) on failure.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState priorState = _state;
    os_unfair_lock_unlock(&_stateLock);
    AudioTrack *trackToRestore = self.currentTrack;
    NSTimeInterval positionToRestore = self.position;
    // Only a live track is restored onto the new device. A finished (Stopped)
    // track still carries currentTrack/_file, so rescheduling it from the saved
    // frame would resurrect it as Paused; a Loading track's open is in flight
    // and will start itself on the new device. Both leave state untouched here.
    BOOL shouldRestore = (priorState == VibePlayerStatePlaying || priorState == VibePlayerStatePaused) && trackToRestore != nil;
    BOOL wasPlaying = (priorState == VibePlayerStatePlaying);

    _generation++;
    [self preemptRampsOnQueue];

    // Unpublish the node BEFORE detaching it: the position getter reads _node
    // lock-free on the main thread, and calling into a detached node raises.
    os_unfair_lock_lock(&_stateLock);
    AVAudioPlayerNode *oldNode = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    [oldNode stop];
    [_engine stop];
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
        // Reuse the already-open handle rather than reopening the URL: a
        // synchronous, timeout-free initForReading: here would wedge the whole
        // queue if the track was evicted to an iCloud/Dropbox placeholder (or
        // sits on a hung mount) between play and the device switch.
        // processingFormat is fixed at open, so rescheduling the existing file
        // on the new node is safe.
        AVAudioFile *file = _file; // safe read: _file is only ever written on _queue, and we're on it
        if (!file) {
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorFileOpenFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:node];
        if (![self connectNode:node throughVarispeedWithFormat:file.processingFormat]) {
            [self detachNodeAfterFailedConnect:node];
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        double sampleRate = file.processingFormat.sampleRate;
        AVAudioFramePosition startFrame = (AVAudioFramePosition)(positionToRestore * sampleRate);
        startFrame = MAX(0, MIN(startFrame, file.length - 1));
        [self scheduleFile:file onNode:node fromFrame:startFrame];
        // Preserve the pause-fade invariant: a Paused track sits at volume 0
        // so the next resume ramps it back up (see setPosition:). Restoring
        // at 1.0 would make that resume start instantly at full volume
        // mid-waveform — the click the 25ms ramp exists to prevent.
        node.volume = wasPlaying ? 1.0 : 0;
        [self publishPlaybackState:(wasPlaying ? VibePlayerStatePlaying : VibePlayerStatePaused)
                              node:node file:file segmentStart:startFrame position:positionToRestore];
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                _generation++;
                [node stop];
                [_engine detachNode:node];
                [self resetToStoppedStateOnQueue];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not restart playback on the new audio device", startError)];
                return NO;
            }
        }
    }

    return YES;
}

// Runs on _queue when the last output device vanished mid-play. A dead engine
// must not sit behind a Playing state (frozen position, no explanation), so
// park as Paused at the last valid position — restorable when a device
// returns (setOutputDevice:-1 rebuilds the graph at this position). No-op
// unless Playing: Paused/Loading report their own failure on the next start
// attempt. No generation bumps — nothing is stopped or rescheduled, same as
// a normal pause landing.
- (void)parkPlaybackForMissingOutputDeviceOnQueue {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    os_unfair_lock_unlock(&_stateLock);
    if (state != VibePlayerStatePlaying) {
        return;
    }
    NSTimeInterval position = self.position; // engine dead: serves the last valid reading
    [self publishPlaybackState:VibePlayerStatePaused node:_node file:_file
                  segmentStart:_segmentStartFrame position:position];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

// AVAudioEngineConfigurationChangeNotification — the output hardware changed
// under the engine (device removed, format/sample-rate change), which makes
// the engine stop itself. Idempotent health check: only rebuild when the
// graph actually died, so notifications caused by our own completed rebuilds
// are no-ops instead of redundant rebuilds.
- (void)handleEngineConfigurationChange {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (requested >= 0) {
        AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:requested];
        if (!device) {
            LogError(@"Audio output device failed; falling back to system default");
            [self setOutputDevice:-1];
            return;
        }
    }
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    BOOL hasNode = (_node != nil);
    os_unfair_lock_unlock(&_stateLock);
    if (state == VibePlayerStateStopped) {
        return;
    }
    if (_engine.isRunning && hasNode) {
        // Graph survived — nothing to recover.
        return;
    }
    // The engine stopped itself in response to the change. Rebuild the graph,
    // preserving track/position/play-pause state.
    AudioDeviceID deviceID = requested >= 0
            ? (AudioDeviceID)requested
            : [CoreAudioUtil systemDefaultOutputDeviceID];
    if (deviceID == kAudioObjectUnknown) {
        // No output device exists at all (the last one vanished): park the
        // track as Paused, restorable when a device returns (see
        // parkPlaybackForMissingOutputDeviceOnQueue), and say why.
        if (state == VibePlayerStatePlaying) {
            [self parkPlaybackForMissingOutputDeviceOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"No audio output device is available", nil)];
        }
        return;
    }
    // Paused idempotence: a Paused rebuild deliberately leaves the engine
    // stopped, so the isRunning check above can't attest graph health for it
    // — without this, every notification while paused re-ran a full rebuild.
    // Node present + right device bound = graph intact; resume starts the
    // engine, same as after a normal idle stop.
    if (state == VibePlayerStatePaused && hasNode && [self activeOutputDeviceID] == deviceID) {
        return;
    }
    [self configureOutputDeviceOnQueue:deviceID];
}

@end

#pragma mark - Output devices (public API, declared in AudioPlayer.h)

@implementation AudioPlayer (Devices)

- (NSInteger)currentlyActiveAudioDeviceId {
    return (NSInteger)[self activeOutputDeviceID];
}

- (void)setOutputDevice:(NSInteger)outputDeviceID {
    dispatch_async(_queue, ^{

        LogDebug(@"setOutputDevice: %@", @(outputDeviceID));

        AudioDeviceID newDeviceID = kAudioObjectUnknown;
        if (outputDeviceID >= 0) {
            newDeviceID = (AudioDeviceID)outputDeviceID;
        }
        else {
            newDeviceID = [CoreAudioUtil systemDefaultOutputDeviceID];
        }

        if (newDeviceID == kAudioObjectUnknown) {
            // No output device left at all (the explicitly chosen device
            // vanished and it was the last one): park like
            // handleEngineConfigurationChange's no-device branch.
            LogError(@"Unable to resolve output device %@", @(outputDeviceID));
            [self parkPlaybackForMissingOutputDeviceOnQueue];
            // outputDeviceID is -1 here in practice: an explicit id >= 0 is
            // used verbatim above, and the only other value that could land
            // in this branch is 0 (== kAudioObjectUnknown), which the HAL
            // never assigns to a device. Recording it matters: a stale
            // explicit id would blind both observer recovery paths; with -1
            // recorded (and persisted by the delegate), the next
            // default-device arrival restores the parked track.
            self.currentlyRequestedAudioDeviceId = outputDeviceID;
            run_on_main_thread({
                [self.delegate audioPlayer:self didChangeOutputDevice:self.currentlyRequestedAudioDeviceId];
            });
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"Audio output device is unavailable", nil)];
            return;
        }

        AudioDeviceID currentDeviceID = [self activeOutputDeviceID];

        LogDebug(@"current: %@ new: %@", @(currentDeviceID), @(newDeviceID));

        if (newDeviceID != currentDeviceID) {
            if (![self configureOutputDeviceOnQueue:newDeviceID]) {
                // configureOutputDeviceOnQueue already reported the error;
                // don't record or persist a device we failed to switch to.
                return;
            }
        }

        self.currentlyRequestedAudioDeviceId = outputDeviceID;

        run_on_main_thread({
            [self.delegate audioPlayer:self didChangeOutputDevice:self.currentlyRequestedAudioDeviceId];
        });

    });
}

@end
