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
#import "AudioFX.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <AudioToolbox/AudioToolbox.h>

static const NSTimeInterval kSystemOutputBindRetryDelay = 2.0;

// Format changes and restoration wait with the engine stopped, before a
// restart can reuse the output unit's old render-buffer sizing.
static const NSTimeInterval kFormatSwitchDeadlineSeconds = 1.5;
static const useconds_t kFormatSwitchPollMicroseconds = 5000;

// Taking the system default costs one output-unit follow, measured at about
// 50 ms. This is the ceiling on waiting for it and for the re-bind after it.
static const NSTimeInterval kHogSettleDeadlineSeconds = 0.5;

// A rebind slower than this held the player queue long enough for the user to
// feel it as a freeze; see #53 and the comment at configureOutputDeviceOnQueue:.
// A bit-perfect switch legitimately reached 0.73s on healthy hardware, so a
// tighter bound would warn about working correctly.
static const NSTimeInterval kSlowDeviceRebindLogThresholdSeconds = 0.25;

#pragma mark - Output devices (internal surface + device-change observing)

@implementation AudioPlayer (DevicesInternal)

// Main thread, and meaningful only inside didChangeOutputDevice: — the
// announcement sets them around the delegate call.
- (NSString *)involuntaryFallbackDeviceUID {
    return _announcedFallbackUID;
}

- (NSString *)involuntaryFallbackDeviceName {
    return _announcedFallbackName;
}

// The device that just went away, moved from "bound" to "wanted again". The
// pending slot is the same one a launch preference waits in, so the existing
// resolve path re-adopts the device when it returns — no new mechanism, and
// VibeCanBindSavedOutputDevice still decides when it is safe to bind.
- (void)retainVanishedOutputDeviceIntentOnQueue {
    if (_boundDeviceUID.length == 0 && _boundDeviceName.length == 0) {
        return;
    }
    _involuntaryFallbackUID = _boundDeviceUID;
    _involuntaryFallbackName = _boundDeviceName;
    _pendingSavedDeviceUID = _boundDeviceUID;
    _pendingSavedDeviceModelUID = _boundDeviceModelUID;
    _pendingSavedDeviceName = _boundDeviceName;
    LogInfo(@"AudioPlayer: keeping '%@' as the wanted output device; it vanished rather than being deselected",
            _boundDeviceName.length ? _boundDeviceName : _boundDeviceUID);
}

- (void)systemDefaultOutputDeviceDidChange {
    dispatch_async(_queue, ^{
        if (self.currentlyRequestedAudioDeviceId == -1) {
            [self setOutputDeviceOnQueue:-1];
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
        [self publishBitPerfectReportOnQueue]; // whether the chosen device is the default moved
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
            [self abandonBitPerfectForVanishedDeviceOnQueue];
            [self retainVanishedOutputDeviceIntentOnQueue];
            [self setOutputDeviceOnQueue:-1];
            self->_involuntaryFallbackUID = nil;
            self->_involuntaryFallbackName = nil;
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
    });
}

// The bind rule read from this player's own state, in one place, so the fast
// path and the async completion cannot disagree about what counts as silent.
- (BOOL)canBindSavedOutputDeviceNowOnQueue {
    return VibeCanBindSavedOutputDevice(_state == VibePlayerStateStopped,
                                        _state == VibePlayerStateLoading,
                                        _state == VibePlayerStatePaused,
                                        _engine.isRunning, _outputAudioActive);
}

// Binds a wanted device the resolver found. When it was found by its model UID
// under a NEW device UID — a class-compliant interface moved to another USB
// port — the bind reads the modes remembered under the old UID, so the device
// comes back as the user left it rather than with bit-perfect off. Only a model
// match earns that: a name match may be a different device, and carrying
// exclusive to it would hog hardware the user never chose — the warning in
// selectOutputDeviceOnQueue: is why. The shell persists the carry on main.
- (BOOL)selectSavedOutputDeviceOnQueue:(AudioDevice *)device
                              savedUID:(NSString *)savedUID
                         savedModelUID:(NSString *)savedModelUID {
    BOOL movedPort = savedUID.length > 0 && ![device.uid isEqualToString:savedUID]
            && savedModelUID.length > 0 && [device.modelUID isEqualToString:savedModelUID];
    if (movedPort) {
        LogInfo(@"AudioPlayer: '%@' is the same model under a new device UID; carrying its modes",
                device.name);
        _modesUIDForNextSelection = savedUID;
    }
    BOOL bound = [self selectOutputDeviceOnQueue:device.deviceId];
    _modesUIDForNextSelection = nil;
    return bound;
}

- (void)resolvePendingSavedOutputDeviceOnQueue {
    NSString *savedUID = _pendingSavedDeviceUID;
    NSString *savedModelUID = _pendingSavedDeviceModelUID;
    NSString *savedName = _pendingSavedDeviceName;
    if (savedUID.length == 0 && savedModelUID.length == 0 && savedName.length == 0) {
        return;
    }
    BOOL canBind = [self canBindSavedOutputDeviceNowOnQueue];
    // TRAP: a returning device must be matched here, synchronously. Once one
    // has come back a snapshot always exists — the replug IS a snapshot refresh
    // — whereas the async lookup below exists for launch, where there may be no
    // snapshot yet. Used for a returning device it lost every time to a fast
    // local open: Loading became Playing before the answer landed, and the rule
    // then refused a bind that would have been legal a moment earlier.
    NSArray<AudioDevice *> *snapshot = [[AudioDeviceManager sharedInstance] cachedOutputDevices];
    if (snapshot && !_pendingSavedDeviceLookupInFlight) {
        AudioDevice *device = [AudioDeviceManager deviceForUID:savedUID modelUID:savedModelUID
                                                          name:savedName inDevices:snapshot];
        if (device && canBind) {
            LogInfo(@"AudioPlayer: re-adopting '%@', the wanted output device, now that it is present",
                    device.name);
            if ([self selectSavedOutputDeviceOnQueue:device savedUID:savedUID savedModelUID:savedModelUID]) {
                _pendingSavedDeviceUID = nil;
                _pendingSavedDeviceName = nil;
                _pendingSavedDeviceModelUID = nil;
            }
            return;
        }
        if (device) {
            LogInfo(@"AudioPlayer: '%@' is present but playback is audible; adopting it once it is not",
                    device.name);
            return;
        }
    }
    // Binding is opportunistic, but an armed mode must also learn about an
    // absent device if playback won the race with discovery.
    if ((!_bitPerfectWanted && !canBind) || _pendingSavedDeviceLookupInFlight) {
        return;
    }
    _pendingSavedDeviceLookupInFlight = YES;
    __weak AudioPlayer *weakSelf = self;
    [[AudioDeviceManager sharedInstance] resolveOutputDeviceForUID:savedUID modelUID:savedModelUID
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
            if (!VibeSavedOutputDeviceRequestIsCurrent(savedUID, savedName,
                            strongSelf->_pendingSavedDeviceUID, strongSelf->_pendingSavedDeviceName)) {
                strongSelf->_pendingSavedDeviceLookupInFlight = NO;
                return;
            }
            // A nil answer follows a published snapshot, never a discovery
            // timeout. Clear the intent before rebuilding so state publication
            // cannot immediately submit the same lookup again.
            if (!device && strongSelf->_bitPerfectWanted) {
                // Absent is not deselected: keep the persisted choice so a later
                // launch re-adopts the device. The in-memory intent is still
                // cleared, because re-arming it here would resubmit this same
                // lookup on the next state publication, forever.
                strongSelf->_involuntaryFallbackUID = strongSelf->_pendingSavedDeviceUID;
                strongSelf->_involuntaryFallbackName = strongSelf->_pendingSavedDeviceName;
                strongSelf->_pendingSavedDeviceUID = nil;
                strongSelf->_pendingSavedDeviceName = nil;
                strongSelf->_pendingSavedDeviceModelUID = nil;
                [strongSelf abandonBitPerfectForVanishedDeviceOnQueue];
                [strongSelf setOutputDeviceOnQueue:-1];
                strongSelf->_involuntaryFallbackUID = nil;
                strongSelf->_involuntaryFallbackName = nil;
            }
            if (!device || ![strongSelf canBindSavedOutputDeviceNowOnQueue]) {
                strongSelf->_pendingSavedDeviceLookupInFlight = NO;
                return;
            }
            if ([strongSelf selectSavedOutputDeviceOnQueue:device savedUID:savedUID
                                             savedModelUID:savedModelUID]) {
                strongSelf->_pendingSavedDeviceUID = nil;
                strongSelf->_pendingSavedDeviceName = nil;
                strongSelf->_pendingSavedDeviceModelUID = nil;
            }
            strongSelf->_pendingSavedDeviceLookupInFlight = NO;
        });
    }];
}

- (AudioDeviceID)activeOutputDeviceID {
#if DEBUG
    if (_engine.isInManualRenderingMode) {
        return [CoreAudioUtil systemDefaultOutputDeviceID]; // no hardware output unit to query
    }
#endif
    AudioUnit outputUnit = _engine.outputNode.audioUnit;
    if (outputUnit) {
        AudioDeviceID deviceID = kAudioObjectUnknown;
        UInt32 size = sizeof(deviceID);
        if (AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, &size) == noErr && deviceID != kAudioObjectUnknown) {
            return deviceID;
        }
    }
    // Bit-perfect needs a confirmed binding; ordinary recovery retains its
    // original system-default fallback.
    return _bitPerfectWanted ? kAudioObjectUnknown : [CoreAudioUtil systemDefaultOutputDeviceID];
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

// Rebuilds the graph, restoring the track, position and play or pause state.
// kAudioObjectUnknown keeps the current binding (a mode toggle on System
// Output needs no device read). On failure it reports a delegate error.
// The report is held throughout. A success is published by the caller once
// the requested id is committed — publishing here would fold the old id
// against the new prepared device — so only the failure reset's held
// publication is owed here.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    _rebindDeviceID = deviceID;
    // The whole rebuild holds the player queue, so every transport action
    // submitted during it waits (#53). A device slow to deliver its first IO
    // cycle can make that seconds. Warn level so it persists and a user can
    // retrieve it with `log show` rather than having to catch it live; the
    // narrower attribution, engine start vs node play, is AudioPlayer+Engine's.
    uint64_t reboundAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL rebound = [self rebindOutputOnQueueToDevice:deviceID];
    NSTimeInterval seconds =
            (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - reboundAt) / NSEC_PER_SEC;
    BOOL slowRebind = seconds > kSlowDeviceRebindLogThresholdSeconds;
    LogTiming(slowRebind, @"AudioPlayer: %@device rebind to %u took %.3fs (%@)",
            slowRebind ? @"slow " : @"", deviceID, seconds, rebound ? @"bound" : @"FAILED");
    _rebindDeviceID = kAudioObjectUnknown;
    if (!rebound) {
        // Names the path that asked for a bind the HAL refused. A rebind onto a
        // device that is vanishing fails with -10851, raises a user-visible
        // error and unloads the track, and it was seen once in three paused
        // unplugs with nothing in the log saying who asked (#62). Failed binds
        // are rare, so the stack costs nothing in ordinary use. A Release build
        // logs addresses, which symbolicate against the archived binary.
        NSArray<NSString *> *stack = [NSThread callStackSymbols];
        NSUInteger depth = MIN(stack.count, (NSUInteger)10);
        NSString *callers = depth > 1
                ? [[stack subarrayWithRange:NSMakeRange(1, depth - 1)] componentsJoinedByString:@" | "] : @"?";
        LogWarn(@"AudioPlayer: rebind to %u failed in state %ld; called from: %@",
                deviceID, (long)_state, callers);
        [self publishBitPerfectReportOnQueue];
    }
    return rebound;
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

// Handles engine configuration and output-unit device changes: the hardware
// can stop the engine or silently move its output to another device. The health check is
// idempotent: bit-perfect also requires the requested device, so
// notifications caused by our own completed rebuilds are no-ops. Whichever
// branch the recovery takes, the report is published once at the end.
- (void)handleEngineConfigurationChange {
    [self recoverEngineConfigurationOnQueue];
    [self publishBitPerfectReportOnQueue];
}

// The output unit's hardware side at the prepared device's rate. An unreadable
// device format is unknown, never a mismatch: a rebuild on a guess is a gap.
- (BOOL)outputUnitAtPreparedDeviceRateOnQueue {
    AudioStreamBasicDescription physical = {0};
    if (_preparedStreamID == kAudioObjectUnknown
            || ![CoreAudioUtil readPhysicalFormat:&physical forStream:_preparedStreamID]) {
        return YES;
    }
    return [_engine.outputNode outputFormatForBus:0].sampleRate == physical.mSampleRate;
}

- (void)recoverEngineConfigurationOnQueue {
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
    // Only the mode requires the requested device: off, the output unit may
    // follow the system default wherever it goes, and the binding is read
    // only for the paused-graph check below, as before the mode existed.
    BOOL onRequestedDevice = !_bitPerfectWanted || requested < 0
            || [self activeOutputDeviceID] == (AudioDeviceID)requested;
    // The mode needs the unit's formats to be that device's too. A pin that
    // collides with the unit following the default connects the device without
    // updating them (see settleOutputUnitAfterHoggingSystemDefaultOnQueue:),
    // and this notification is the one edge left to catch that on: #47's
    // launch with exclusive on played the whole session "switch failed".
    BOOL unitAtDeviceRate = !_bitPerfectWanted || requested < 0
            || (AudioDeviceID)requested != _preparedDeviceID || [self outputUnitAtPreparedDeviceRateOnQueue];
    BOOL graphHealthy = _engine.isRunning && hasNode && onRequestedDevice && unitAtDeviceRate;
#if VIBE_VERBOSE_LOGGING
    // Beta instrumentation (#47): every recovery says what it saw and what it
    // decided. "Healthy, nothing to do" used to be silent, which is how a unit
    // at the wrong rate went unnoticed for a whole session.
    NSString *seen = [NSString stringWithFormat:@"engine %@, node %@, requested %ld, bound %u, unit at device rate %@, state %ld",
                      _engine.isRunning ? @"running" : @"stopped", hasNode ? @"present" : @"absent", (long)requested,
                      [self activeOutputDeviceID], unitAtDeviceRate ? @"yes" : @"NO", (long)state];
#endif
    if (!graphHealthy) {
        // Publish the stopped graph before any recovery branch can wait or
        // return. Transport state intentionally remains unchanged so a
        // successful rebuild can resume it.
        [self refreshOutputAudioActiveOnQueue];
    }
    // TRAP: the snapshot lags an unplug. It only refreshes when the device-list
    // notification is processed, and while a bit-perfect device is prepared the
    // output-unit listener can fire first — the unit has already followed the
    // default off the vanished device. knowsOutputDeviceIsAbsent then still
    // answers NO, recovery fell through to rebind onto a device that no longer
    // existed, and that failed with -10851, raised a user-visible error and
    // unloaded the track (#62). So ask the device itself too. Only a confirmed
    // "dead" counts: a failed read is unknown, never removal.
    BOOL snapshotKnowsAbsent = [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:requested];
    if (snapshotKnowsAbsent
            || (requested >= 0 && [CoreAudioUtil deviceIsConfirmedDead:(AudioDeviceID)requested])) {
        // Which check caught it is the difference between the snapshot keeping
        // up and this guard earning its place, so say which.
        LogError(@"Audio output device failed; falling back to system default (%@)",
                 snapshotKnowsAbsent ? @"the device list had caught up"
                                     : @"the device list was stale; the device itself reports gone");
        [self abandonBitPerfectForVanishedDeviceOnQueue];
        [self retainVanishedOutputDeviceIntentOnQueue];
        [self setOutputDeviceOnQueue:-1];
        _involuntaryFallbackUID = nil;
        _involuntaryFallbackName = nil;
        return;
    }
    // Nothing to recover while idle. In bit-perfect mode, Loading may have no
    // running engine — its settlement will start it, and rebinding the same
    // device here only produces another notification while leaving that open
    // waiting on this queue — but idle on the wrong device still rebinds.
    BOOL idle = state == VibePlayerStateStopped
            || (_bitPerfectWanted && state == VibePlayerStateLoading);
    if (idle && onRequestedDevice) {
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Recovery: idle on the requested device, nothing to do (%@)", seen);
#endif
        return;
    }
    if (graphHealthy) {
        // The graph survived, so there is nothing to recover.
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Recovery: graph healthy, nothing to do (%@)", seen);
#endif
        return;
    }
    // The engine stopped or left the chosen device. Rebuild while preserving
    // transport; a Stopped player only rebinds, without resurrecting its file.
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
    // full rebuild. A node present, the right device bound and the device
    // still at the format the mode set means the graph is intact, and the
    // resume starts the engine, just as after a normal idle stop. A format
    // another process moved during the pause is what this notification
    // often IS, and the rebuild's prepare sets it back.
    if (state == VibePlayerStatePaused && hasNode && [self activeOutputDeviceID] == deviceID && unitAtDeviceRate
            && !(_file && [self outputNeedsSwitchOnQueueForFile:_file unknownNeedsSwitch:NO])) {
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Recovery: paused with the graph intact, nothing to do (%@)", seen);
#endif
        return;
    }
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Recovery: rebinding to device %u (%@)", deviceID, seen);
#endif
    [self configureOutputDeviceOnQueue:deviceID];
}

#pragma mark - Output device mutation

- (void)readOutputModesForDeviceUID:(NSString *)deviceUID
                  bitPerfectOutput:(BOOL *)bitPerfectOutput
                   exclusiveOutput:(BOOL *)exclusiveOutput {
    id<AudioPlayerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(audioPlayer:outputModesForDeviceUID:bitPerfectOutput:exclusiveOutput:)]) {
        [delegate audioPlayer:self outputModesForDeviceUID:deviceUID
             bitPerfectOutput:bitPerfectOutput exclusiveOutput:exclusiveOutput];
    }
}

- (BOOL)selectOutputDeviceOnQueue:(NSInteger)outputDeviceID {
    BOOL bitPerfectOutput = NO, exclusiveOutput = NO;
    NSString *uid = [AudioDeviceManager.sharedInstance outputDeviceForId:outputDeviceID].uid;
    // TRAP: a name fallback can resolve a different UID; read its own modes
    // before preparing or hogging it, never the missing device's flags. A name
    // match may be different hardware, and carrying exclusive to it would hog a
    // device the user never enabled it on. The ONE exception is
    // _modesUIDForNextSelection: set only when the device was matched by its
    // documented model UID under a new device UID, which is the same model on
    // another USB port, not a stranger that shares a name.
    [self readOutputModesForDeviceUID:(_modesUIDForNextSelection ?: uid)
                     bitPerfectOutput:&bitPerfectOutput exclusiveOutput:&exclusiveOutput];
    BOOL previousBitPerfect = _bitPerfectWanted;
    _bitPerfectWanted = bitPerfectOutput;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    BOOL previousExclusive = _exclusiveOutputWanted;
    _exclusiveOutputWanted = exclusiveOutput;
#endif
    BOOL didBind = [self setOutputDeviceOnQueue:outputDeviceID];
    if (self.currentlyRequestedAudioDeviceId != outputDeviceID) {
        _bitPerfectWanted = previousBitPerfect;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        _exclusiveOutputWanted = previousExclusive;
#endif
        // TRAP: a failed rebuild may already have rewired or prepared the
        // destination. A failed pin leaves live playback untouched.
        if (_state == VibePlayerStateStopped) {
            [_engine stop];
            [self leaveOutputDeviceOnQueue];
        }
        // Reset may have cleared Settings before this failed bind. Reannounce
        // the retained choice, unless a saved launch preference still owns it.
        if (_pendingSavedDeviceUID.length || _pendingSavedDeviceName.length) {
            [self publishBitPerfectReportOnQueue];
        }
        else {
            [self notifyRequestedOutputDeviceOnQueue];
        }
    }
    else if (!didBind && previousBitPerfect != _bitPerfectWanted) {
        // System Output commits even without a resolved device. Its mode
        // change must still restore the ordinary graph on the current binding.
        [self configureOutputDeviceOnQueue:kAudioObjectUnknown];
        [self publishBitPerfectReportOnQueue];
    }
    return didBind;
}

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

- (BOOL)rebindOutputOnQueueToDevice:(AudioDeviceID)deviceID {
    // Phase timings for #53. A rebind holds the player queue for its whole
    // duration, and the phases fail for different reasons: the format restore
    // and the prepare each confirm a write by polling up to
    // kFormatSwitchDeadlineSeconds, so a device that will not confirm burns that
    // deadline twice before the engine is even started, while a device that
    // confirms instantly but will not cycle IO spends it all in the start. A
    // single total cannot tell those apart, and the remedies are opposite.
    uint64_t phaseAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSTimeInterval teardownS = 0, leaveS = 0, pinS = 0, restoreS = 0, startS = 0;
#define VIBE_REBIND_PHASE(accum) do { \
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); \
        (accum) = (double)(now - phaseAt) / NSEC_PER_SEC; \
        phaseAt = now; \
    } while (0)

    os_unfair_lock_lock(&_stateLock);
    VibePlayerState priorState = _state;
    os_unfair_lock_unlock(&_stateLock);
    AudioTrack *trackToRestore = self.currentTrack;
    // Only a live track is restored onto the new device. A finished, Stopped
    // track still carries currentTrack and _file, so rescheduling it from the
    // saved frame would resurrect it as Paused. A Loading track's open is in
    // flight and will start itself on the new device. Both leave the state
    // untouched here.
    VibePendingPlaybackIntent intent;
    BOOL shouldRestore = priorState != VibePlayerStateLoading && trackToRestore
            && [self getPlaybackIntent:&intent forTrack:trackToRestore];
    NSTimeInterval positionToRestore = shouldRestore ? intent.position : 0;
    BOOL wasPlaying = shouldRestore && !intent.paused;

    _segmentGeneration++;
    [self preemptRampsOnQueue];
    if (_bitPerfectWanted) {
        [self preemptRetiredFadesOnQueue]; // the mode may land during an incoming open
    }
    [self setGaplessQueuedOnQueue:NO]; // the queued segment dies with the old node

    // Unpublish the node before detaching it: the position getter uses its
    // snapshot of _node off the lock on the main thread, and calling into a
    // detached node raises.
    AVAudioPlayerNode *oldNode = [self unpublishNodeOnQueue];
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
    VIBE_REBIND_PHASE(teardownS);

    // Restore and release only after the engine stopped. Restoring a hogged
    // device's format under a running engine can strand its next start in
    // CoreAudio (error 35). A same-device recovery keeps the format and hog
    // while their settings still want them.
    if (!_bitPerfectWanted || (_preparedDeviceID != kAudioObjectUnknown && _preparedDeviceID != deviceID)) {
        [self leaveOutputDeviceOnQueue];
    }
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    else if (!_exclusiveOutputWanted) {
        [self releaseExclusiveOutputOnQueue];
    }
#endif
    VIBE_REBIND_PHASE(leaveS);

    if (deviceID != kAudioObjectUnknown && ![self setOutputUnitDevice:deviceID]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not switch audio output device", nil)];
        return NO;
    }
    if ((self.fx.masterBusOutputNode != nil) != (_fxEnabled && !_bitPerfectWanted)) {
        [self installMasterBusOnQueue];
    }
    // A toggle off during a pending open must restore the incoming chain too.
    // Ordinary playback already created it when the play was submitted.
    if (_bitPerfectWanted || priorState == VibePlayerStateLoading || shouldRestore) {
        [self ensureVarispeedOnQueue];
    }
    VIBE_REBIND_PHASE(pinS);

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
        if (_bitPerfectWanted) {
            [self prepareOutputOnQueueForFile:file];
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
        VIBE_REBIND_PHASE(restoreS);
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                [self abandonNodeAfterFailedStart:node];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not restart playback on the new audio device", startError)];
                return NO;
            }
        }
        else {
            [self scheduleEngineIdleStopOnQueue];
            // The rebuild consumed a pause whose fade had not settled yet.
            if (priorState == VibePlayerStatePlaying) {
                run_on_main_thread({
                    [self.delegate audioPlayer:self didPausePlaying:trackToRestore];
                });
            }
        }
        [self maybeArmGaplessOnQueue]; // re-queue the splice behind the restored segment
    }
    VIBE_REBIND_PHASE(startS);

    NSTimeInterval total = teardownS + leaveS + pinS + restoreS + startS;
    if (total > kSlowDeviceRebindLogThresholdSeconds) {
        LogWarn(@"AudioPlayer: slow rebind to %u, %.3fs total — teardown %.3f, "
                @"leave/restore-format %.3f, pin+graph %.3f, reschedule %.3f, "
                @"engine start %.3f", deviceID, total, teardownS, leaveS, pinS,
                restoreS, startS);
    }
    return YES;
}
#undef VIBE_REBIND_PHASE

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

    LogWarn(@"AudioPlayer: rebind current: %@ new: %@%@", @(currentDeviceID), @(newDeviceID),
            currentDeviceID == newDeviceID ? @" (no-op)" : @"");

    // Choosing the already-active System Output device can make a wanted
    // mode eligible for the first time. Rebuild so the current track gets
    // prepared too; merely pinning the unit would leave its old rate behind.
    // The same holds for a switch whose destination wants the mode off while
    // this device is its system default too: the unit does not move, but the
    // prepared device and the FX route are still the mode's.
    BOOL needsPreparation = (_bitPerfectWanted
            ? outputDeviceID >= 0 && _preparedDeviceID != newDeviceID
            : (_node && !self.varispeed) || _preparedDeviceID != kAudioObjectUnknown)
            || (self.fx.masterBusOutputNode != nil) != (_fxEnabled && !_bitPerfectWanted);
    if (newDeviceID != currentDeviceID || needsPreparation) {
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
    if (outputDeviceID >= 0) {
        AudioDevice *committed = [[AudioDeviceManager sharedInstance] outputDeviceForId:newDeviceID];
        _boundDeviceUID = committed.uid;
        _boundDeviceModelUID = committed.modelUID;
        _boundDeviceName = committed.name;
    }
    else if (!_involuntaryFallbackUID) {
        // System Output the user actually chose: nothing to re-adopt later.
        _boundDeviceUID = nil;
        _boundDeviceModelUID = nil;
        _boundDeviceName = nil;
    }
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
    // The report's eligibility follows the committed id, which the rebuild
    // above ran before this was written.
    [self publishBitPerfectReportOnQueue];
    // TRAP: copied here, by value. The announcement lands on main
    // asynchronously while the caller clears the queue-side fields straight
    // after, so a delegate reading them from main would see nil and erase the
    // very choice this exists to keep.
    NSString *fallbackUID = _involuntaryFallbackUID;
    NSString *fallbackName = _involuntaryFallbackName;
    run_on_main_thread({
        self->_announcedFallbackUID = fallbackUID;
        self->_announcedFallbackName = fallbackName;
        [self.delegate audioPlayer:self didChangeOutputDevice:requested];
        self->_announcedFallbackUID = nil;
        self->_announcedFallbackName = nil;
    });
}

#pragma mark - Bit-perfect output

- (VibeBitPerfectReport)bitPerfectReport {
    os_unfair_lock_lock(&_stateLock);
    VibeBitPerfectReport report = _bitPerfectReport;
    os_unfair_lock_unlock(&_stateLock);
    return report;
}

#pragma mark - Bit-perfect output (queue-side mechanism)

// The chosen device when it is one the mode may drive, else nil: the one
// eligibility fold, shared by the report and the mechanism. During a device
// switch it is the destination, which configureOutputDeviceOnQueue: prepares
// and hogs before setOutputDeviceOnQueue: commits the id (a failed switch
// must not). Never the output unit's own device: AVAudioEngine's default
// output unit follows the system default whenever it moves — which a hog
// makes it do — so that reading names a device the engine is about to leave.
- (nullable AudioDevice *)eligibleRequestedDeviceOnQueue {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (_rebindDeviceID != kAudioObjectUnknown) {
        requested = (NSInteger)_rebindDeviceID;
    }
    if (requested < 0) {
        return nil;
    }
    AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:requested];
    return (device && VibeBitPerfectDeviceEligible(device.transportType)) ? device : nil;
}

// The device the mode can apply to right now, else nil.
- (nullable AudioDevice *)bitPerfectDeviceOnQueue {
    if (!_bitPerfectWanted) {
        return nil;
    }
#if DEBUG
    if (_engine.isInManualRenderingMode) {
        return nil;
    }
#endif
    return [self eligibleRequestedDeviceOnQueue];
}

// Reads the device and resolves the format the rules want for `file`: the
// stream, what it has now and what it should have. chosen == current when the
// device offers neither the file's rate nor a multiple, or nothing at the
// target rate.
- (BOOL)resolveOutputFormatOnQueueForFile:(AVAudioFile *)file
                                   device:(AudioDevice *)device
                                   stream:(AudioStreamID *)stream
                                  current:(AudioStreamBasicDescription *)current
                                   chosen:(AudioStreamBasicDescription *)chosen {
    AudioStreamRangedDescription *formats = NULL;
    UInt32 count = 0;
    if (![CoreAudioUtil readOutputStream:stream physicalFormat:current
                        availableFormats:&formats count:&count
                             forDeviceID:(AudioDeviceID)device.deviceId]) {
        return NO;
    }
    AudioStreamBasicDescription source = *file.fileFormat.streamDescription;
    double targetRate = VibeBitPerfectTargetRate(source.mSampleRate, source.mChannelsPerFrame, formats, count);
    if (targetRate == 0 || !VibeBitPerfectChooseFormat(source, targetRate, formats, count, chosen)) {
        *chosen = *current;
    }
    free(formats);
    return YES;
}

- (BOOL)outputNeedsSwitchOnQueueForFile:(AVAudioFile *)file unknownNeedsSwitch:(BOOL)unknownNeedsSwitch {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    if (!device) {
        return NO;
    }
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription current = {0}, chosen = {0};
    if (![self resolveOutputFormatOnQueueForFile:file device:device stream:&stream
                                         current:&current chosen:&chosen]) {
        return unknownNeedsSwitch;
    }
    return VibeBitPerfectOutputNeedsSwitch(current, chosen,
            [_engine.mainMixerNode outputFormatForBus:0].sampleRate);
}

// The chosen device vanished: the mode cannot follow the fallback onto System
// Output. The off path verbatim — a confirmed removal retires any restore
// obligation. The shell persists System Output on the -1 announcement;
// the vanished device keeps its remembered modes.
- (void)abandonBitPerfectForVanishedDeviceOnQueue {
    if (!_bitPerfectWanted) {
        return;
    }
    LogInfo(@"bit-perfect: the chosen device vanished; turning the mode off");
    _bitPerfectWanted = NO;
    [_engine stop];
    [self leaveOutputDeviceOnQueue];
    // The fallback may already be bound, or no device may remain. A pending
    // open still needs the ordinary chain before its off-mode settlement.
    if (_state == VibePlayerStateLoading) {
        [self ensureVarispeedOnQueue];
    }
    [self publishBitPerfectReportOnQueue];
}

- (BOOL)setOutputFormatOnQueue:(AudioStreamBasicDescription)format
                       stream:(AudioStreamID)stream device:(AudioDeviceID)deviceID {
    if (![CoreAudioUtil setPhysicalFormat:format forStream:stream]) {
        return NO;
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kFormatSwitchDeadlineSeconds;
    // TRAP: an accepted write and even the nominal rate can precede the
    // output unit. Starting then leaves stale render-buffer sizing and
    // node.play waiting for IO that fails with TooManyFramesToProcess.
    // Restoration must confirm the full sample representation too, including packing.
    do {
        AudioStreamBasicDescription current = {0};
        Float64 rate = 0;
        if ([CoreAudioUtil readPhysicalFormat:&current forStream:stream]
                && VibePhysicalFormatsEquivalent(current, format)
                && [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                && rate == format.mSampleRate
                && ([self activeOutputDeviceID] != deviceID
                    || [_engine.outputNode outputFormatForBus:0].sampleRate == rate)) {
            return YES;
        }
        usleep(kFormatSwitchPollMicroseconds);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return NO;
}

- (void)prepareOutputOnQueueForFile:(AVAudioFile *)file {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    if (!device) {
        return; // the state publication that follows every caller publishes the report
    }
    AudioDeviceID deviceID = (AudioDeviceID)device.deviceId;
    if (![self setPreparedDeviceOnQueue:deviceID]) {
        return;
    }
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription current = {0}, chosen = {0};
    if (![self resolveOutputFormatOnQueueForFile:file device:device stream:&stream
                                         current:&current chosen:&chosen]) {
        LogWarn(@"bit-perfect: could not read the output stream of %@", device.name);
        _preparedStreamID = kAudioObjectUnknown;
        memset(&_preparedFormat, 0, sizeof(_preparedFormat));
        return;
    }
    _preparedStreamID = stream;
    _preparedFormat = chosen;
    BOOL formatDiffers = !VibePhysicalFormatsEquivalent(chosen, current);
    if (VibeBitPerfectOutputNeedsSwitch(current, chosen,
            [_engine.mainMixerNode outputFormatForBus:0].sampleRate)) {
        // Nothing is audible by construction — the settlement parked until the
        // outgoing fades completed, and the device restore stopped the engine
        // itself — so the switch may stop it.
        [_engine stop];
    }
    if (formatDiffers) {
        // Restore is one slot: another device's outstanding restore is tried
        // first, and while it keeps failing this device keeps its format.
        BOOL owedElsewhere = _changedFormatDeviceID != kAudioObjectUnknown && _changedFormatDeviceID != deviceID;
        if (owedElsewhere) {
            [self restoreOutputFormatOnQueue]; // the engine was stopped above
            owedElsewhere = _changedFormatDeviceID != kAudioObjectUnknown;
        }
        if (owedElsewhere) {
            LogWarn(@"bit-perfect: leaving device %u unchanged until device %u is restored",
                    deviceID, _changedFormatDeviceID);
        }
        else {
            // Remember what the device had before OUR first change. A slot already
            // naming this device keeps its older memory: the restore should land
            // on what the user had, not on the previous track's rate.
            if (_changedFormatDeviceID != deviceID) {
                _changedFormatDeviceID = deviceID;
                _changedFormatStreamID = stream;
                _formatBeforeChange = current;
            }
            NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
            BOOL confirmed = [self setOutputFormatOnQueue:chosen stream:stream device:deviceID];
            LogInfo(@"bit-perfect: %@ -> %.0f Hz %@%u in %.0f ms%@", device.name, chosen.mSampleRate,
                    VibePhysicalFormatIsFloat(chosen) ? @"f" : @"i", (unsigned)chosen.mBitsPerChannel,
                    (NSProcessInfo.processInfo.systemUptime - started) * 1000,
                    confirmed ? @"" : @" (not confirmed)");
            // What the device actually has now, not what was asked for.
            [CoreAudioUtil readPhysicalFormat:&current forStream:stream];
        }
    }
    AVAudioFormat *format = [_engine.mainMixerNode outputFormatForBus:0];
    if (format.sampleRate != current.mSampleRate) {
        if (!_masterBusFormatBeforeBitPerfect) {
            _masterBusFormatBeforeBitPerfect = format;
        }
        AudioStreamBasicDescription description = *format.streamDescription;
        description.mSampleRate = current.mSampleRate;
        [self reconnectMasterBusOnQueueWithFormat:[[AVAudioFormat alloc]
                initWithStreamDescription:&description channelLayout:format.channelLayout]];
        LogInfo(@"bit-perfect: master bus reconnected at %.0f Hz", current.mSampleRate);
    }
}

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
// TRAP: taking the device macOS currently points at makes coreaudiod move the
// system default elsewhere, and AVAudioEngine's output unit — a default output
// unit whatever kAudioOutputUnitProperty_CurrentDevice last named — then
// follows the default off the device it was just bound to. Measured on a
// Fireface 802: the default has already moved when the hog write returns, but
// the unit follows about 50 ms LATER, so reading the unit straight after the
// take still names our device and means nothing. Pinning inside that window is
// simply followed again, and an engine started inside it never gets an IO
// cycle — [AVAudioPlayerNode play] then blocks 5 s in awaitIOCycle and the
// recovery rebuilds the graph underneath it. So wait for the follow to land
// and only then pin the unit back, leaving the caller's engine start the one
// configuration edge outstanding. Reproducible in hogfollow.swift (vibe-debug);
// the engine is stopped at every ownership edge, so none of this is audible.
// Even after the unit has left, the pin can collide with the follow's own
// SelectDevice still finishing (#47's A300, at launch): AUHAL answers 'nope'
// having connected the device's IO but not the unit's formats, and a
// same-device pin is then a no-op. recoverEngineConfigurationOnQueue's rate
// check is what repairs that, on the configuration change that follows.
// TRAP: do not reach for -[AVAudioEngine prepare] here. It dispatch_syncs onto
// the AVAudioIOUnit queue, which is draining the property listener for the very
// re-bind above and is blocked in CoreAudio while the HAL reorganizes around
// the take: the player queue then deadlocks against it and the whole app hangs.
- (void)settleOutputUnitAfterHoggingSystemDefaultOnQueue:(AudioDeviceID)deviceID {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kHogSettleDeadlineSeconds;
    // The unit leaving is the observable end of the default move that caused
    // it, so this needs no second reading of the default.
    while (NSProcessInfo.processInfo.systemUptime < deadline
            && [self activeOutputDeviceID] == deviceID) {
        usleep(kFormatSwitchPollMicroseconds);
    }
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        if ([self activeOutputDeviceID] == deviceID) {
            return;
        }
        [self setOutputUnitDevice:deviceID];
        usleep(kFormatSwitchPollMicroseconds);
    }
    LogWarn(@"bit-perfect: output unit did not settle on device %u after taking exclusive use", deviceID);
}

// The engine is stopped at both ownership edges.
- (void)acquireExclusiveOutputOnQueue {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    AudioDeviceID deviceID = device ? (AudioDeviceID)device.deviceId : kAudioObjectUnknown;
    if (!device || !_exclusiveOutputWanted
            || ![CoreAudioUtil supportsHogModeForDeviceID:deviceID]) {
        [self releaseExclusiveOutputOnQueue];
        return;
    }
    if (_hoggedDeviceID != deviceID) {
        [self releaseExclusiveOutputOnQueue];
        if (_hoggedDeviceID != kAudioObjectUnknown) {
            return; // never overwrite an outstanding release with a second device
        }
    }
    // A follow is coming only when the take has a default to move AND the unit
    // is bound to the device being taken. Both are read BEFORE the take, which
    // moves them. An unreadable default counts as "this is it": the settle is
    // bounded, while skipping it strands the engine on whichever device the
    // HAL moved to.
    AudioDeviceID systemDefault = kAudioObjectUnknown;
    BOOL followExpected = (![CoreAudioUtil readSystemDefaultOutputDeviceID:&systemDefault]
                    || systemDefault == deviceID)
            && [self activeOutputDeviceID] == deviceID;
    // A successful write followed by a failed read-back may still own the
    // device. Record the cleanup obligation BEFORE asking the HAL to take it.
    _hoggedDeviceID = deviceID;
    if (![CoreAudioUtil setHogOwnedByThisProcess:YES forDeviceID:deviceID]) {
        LogWarn(@"bit-perfect: could not confirm exclusive access to %@", device.name);
        [self releaseExclusiveOutputOnQueue]; // publishes
        return;
    }
    if (followExpected) {
        [self settleOutputUnitAfterHoggingSystemDefaultOnQueue:deviceID];
    }
    [self publishBitPerfectReportOnQueue];
}

- (void)releaseExclusiveOutputOnQueue {
    if (_hoggedDeviceID == kAudioObjectUnknown) {
        return;
    }
    // Retry once for a transient failure. The HAL helper reads before writing,
    // so a failed read-back after a successful release cannot toggle it back on.
    [CoreAudioUtil releaseDeviceObligation:&_hoggedDeviceID attempt:^BOOL{
        return [CoreAudioUtil setHogOwnedByThisProcess:NO forDeviceID:self->_hoggedDeviceID];
    } isAbsent:^BOOL(AudioDeviceID deviceID) {
        return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:deviceID];
    }];
    if (_hoggedDeviceID != kAudioObjectUnknown) {
        LogWarn(@"bit-perfect: release still owed to device %u", _hoggedDeviceID);
    }
    [self publishBitPerfectReportOnQueue];
}

#endif

// Watch the output binding and the prepared device's volume/balance/mute.
// kAudioObjectUnknown removes both listeners. Copy the HAL block before adding
// it, because removal must receive the same block object.
- (BOOL)setPreparedDeviceOnQueue:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown && _outputDeviceListener) {
        if (AUListenerDispose(_outputDeviceListener) != noErr) {
            return NO;
        }
        _outputDeviceListener = NULL;
    }
    if (_preparedDeviceID == deviceID
            && ((_outputLevelListener && _outputDeviceListener) || deviceID == kAudioObjectUnknown)) {
        return YES;
    }
    // The third device obligation, and it retires like the other two. A device
    // that vanished can never accept the removal, and this used to fail
    // forever: the early return below left _preparedDeviceID naming the gone
    // device, and needsPreparation reads that as "a device is prepared", so
    // every later bind rebuilt the graph and held the player queue (#56).
    if (_outputLevelListener) {
        AudioObjectPropertyListenerBlock listener = _outputLevelListener;
        if ([CoreAudioUtil releaseDeviceObligation:&_preparedDeviceID attempt:^BOOL{
            return [CoreAudioUtil removeOutputLevelListener:listener queue:self->_queue
                                                forDeviceID:self->_preparedDeviceID];
        } isAbsent:^BOOL(AudioDeviceID absentID) {
            return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:absentID];
        }]) {
            _outputLevelListener = nil;
            _preparedStreamID = kAudioObjectUnknown;
            memset(&_preparedFormat, 0, sizeof(_preparedFormat));
        }
        else {
            LogWarn(@"bit-perfect: output listener removal still owed to device %u", _preparedDeviceID);
            return NO; // retain the HAL's removal handle; never accumulate orphaned listeners
        }
    }
    if (_preparedDeviceID != deviceID) {
        _preparedDeviceID = deviceID;
        _preparedStreamID = kAudioObjectUnknown;
        memset(&_preparedFormat, 0, sizeof(_preparedFormat));
    }
    if (deviceID == kAudioObjectUnknown) {
        return YES;
    }
    __weak AudioPlayer *weakSelf = self;
    if (!_outputDeviceListener && _engine.outputNode.audioUnit) {
        AudioUnit outputUnit = _engine.outputNode.audioUnit;
        OSStatus status = AUEventListenerCreateWithDispatchQueue(
                &_outputDeviceListener, 0.01, 0.01, _queue,
                ^(void *object, const AudioUnitEvent *event, UInt64 time, AudioUnitParameterValue value) {
                    AudioPlayer *strongSelf = weakSelf;
#if VIBE_VERBOSE_LOGGING
                    AudioUnitPropertyID property = event->mArgument.mProperty.mPropertyID;
                    LogInfo(@"Callback: output unit %@ changed; bound to device %u",
                            property == kAudioOutputUnitProperty_CurrentDevice ? @"current device" : @"channel map",
                            [strongSelf activeOutputDeviceID]);
#endif
                    // Rebinding from the AU event drain can keep that drain
                    // alive forever. Recover on the next queue turn instead,
                    // if the mode still wants this listener by then.
                    if (strongSelf && strongSelf->_bitPerfectWanted) {
                        dispatch_async(strongSelf->_queue, ^{
                            if (strongSelf->_bitPerfectWanted) {
                                [strongSelf handleEngineConfigurationChange];
                            }
                        });
                    }
                });
        if (status == noErr) {
            AudioUnitEvent event = { .mEventType = kAudioUnitEvent_PropertyChange,
                .mArgument.mProperty = { outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0 } };
            status = AUEventListenerAddEventType(_outputDeviceListener, NULL, &event);
            if (status == noErr) {
                event.mArgument.mProperty.mPropertyID = kAudioOutputUnitProperty_ChannelMap;
                event.mArgument.mProperty.mScope = kAudioUnitScope_Input;
                status = AUEventListenerAddEventType(_outputDeviceListener, NULL, &event);
            }
        }
        if (status != noErr) {
            LogDebug(@"bit-perfect: output device listener failed: %d", (int)status);
            if (_outputDeviceListener) AUListenerDispose(_outputDeviceListener);
            _outputDeviceListener = NULL;
        }
    }
    AudioObjectPropertyListenerBlock listener = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_bitPerfectWanted && strongSelf->_preparedDeviceID == deviceID) {
            for (UInt32 i = 0; i < count; i++) {
                AudioObjectPropertySelector selector = addresses[i].mSelector;
#if VIBE_VERBOSE_LOGGING
                LogInfo(@"Callback: bit-perfect device listener, '%c%c%c%c' changed on device %u", (char)(selector >> 24),
                        (char)(selector >> 16), (char)(selector >> 8), (char)selector, deviceID);
#endif
                if (selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                        || selector == kAudioHardwareServiceDeviceProperty_VirtualMainBalance
                        || selector == kAudioDevicePropertyVolumeScalar
                        || selector == kAudioDevicePropertyVolumeDecibels
                        || selector == kAudioDevicePropertyStereoPan
                        || selector == kAudioDevicePropertyMute
                        || selector == kAudioObjectPropertySelectorWildcard) {
                    [strongSelf publishBitPerfectReportOnQueue];
                    break;
                }
            }
        }
    } copy];
    // Retry a transient registration failure once, and again at the next
    // prepare if both attempts fail. Keep the prepared format on that retry.
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        if ([CoreAudioUtil addOutputLevelListener:listener queue:_queue forDeviceID:deviceID]) {
            _outputLevelListener = listener;
            break;
        }
    }
    return YES; // a registration failure is reported as unconfirmed, and retried at the next prepare
}

// The engine must be stopped. Retry once, then keep the obligation for the
// next leave or prepare (including quit). A second device cannot replace it.
- (void)restoreOutputFormatOnQueue {
    if (_changedFormatDeviceID == kAudioObjectUnknown) {
        return;
    }
    BOOL cleared = [CoreAudioUtil releaseDeviceObligation:&_changedFormatDeviceID attempt:^BOOL{
        BOOL restored = [self setOutputFormatOnQueue:self->_formatBeforeChange
                                             stream:self->_changedFormatStreamID device:self->_changedFormatDeviceID];
        if (restored) {
            LogInfo(@"bit-perfect: device %u restored to %.0f Hz %@%u", self->_changedFormatDeviceID,
                    self->_formatBeforeChange.mSampleRate, VibePhysicalFormatIsFloat(self->_formatBeforeChange) ? @"f" : @"i",
                    (unsigned)self->_formatBeforeChange.mBitsPerChannel);
        }
        return restored;
    } isAbsent:^BOOL(AudioDeviceID deviceID) {
        return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:deviceID];
    }];
    if (cleared) {
        _changedFormatStreamID = kAudioObjectUnknown;
        memset(&_formatBeforeChange, 0, sizeof(_formatBeforeChange));
    }
    else {
        LogWarn(@"bit-perfect: format restore still owed to device %u", _changedFormatDeviceID);
    }
}

// Restore the original format, forget the prepared device and release it.
// Every step is idempotent, so this is free to call with nothing owed.
- (void)leaveOutputDeviceOnQueue {
    if (_masterBusFormatBeforeBitPerfect
            || (self.fx.masterBusOutputNode != nil) != (_fxEnabled && !_bitPerfectWanted)) {
        [self reconnectMasterBusOnQueueWithFormat:_masterBusFormatBeforeBitPerfect
                ?: [_engine.mainMixerNode outputFormatForBus:0]];
        _masterBusFormatBeforeBitPerfect = nil;
    }
    [self restoreOutputFormatOnQueue];
    [self setPreparedDeviceOnQueue:kAudioObjectUnknown];
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    [self releaseExclusiveOutputOnQueue];
#endif
}

// Computes the report from its owners — the mode, the graph, the chosen
// device, the hog, the current file, and the prepared device's physical
// format, volume, balance, mute and default-ness read live — and publishes the copy the
// shell reads, announcing it to the delegate when it differs. Held while a
// device switch is rebuilding; the switch's caller publishes once the
// requested id is committed. It gates itself: off, once the zeroed Off
// report is out, a call is two ivar reads, so callers never repeat the check.
- (void)publishBitPerfectReportOnQueue {
    if (_rebindDeviceID != kAudioObjectUnknown || (!_bitPerfectWanted && !_bitPerfectReport.enabled)) {
        return;
    }
    VibeBitPerfectReport report = {0};
    NSString *unconfirmed = nil;
    report.enabled = _bitPerfectWanted;
    AudioDevice *device = _bitPerfectWanted ? [self eligibleRequestedDeviceOnQueue] : nil;
    report.eligibleDevice = (device != nil);
    if (device && (AudioDeviceID)device.deviceId == _preparedDeviceID) {
        AudioStreamBasicDescription physical = {0};
        BOOL readFormat = [CoreAudioUtil readPhysicalFormat:&physical forStream:_preparedStreamID];
        AVAudioFormat *mixerFormat = [_engine.mainMixerNode outputFormatForBus:0];
        AVAudioFormat *outputInputFormat = [_engine.outputNode inputFormatForBus:0];
        report.sampleRate = physical.mSampleRate;
        report.bitsPerChannel = physical.mBitsPerChannel;
        report.isFloat = VibePhysicalFormatIsFloat(physical);
        // Named rather than folded into one flag: "switch failed" alone sent #47
        // round the houses, and the debug info log is where this is read.
        AudioDeviceID bound = [self activeOutputDeviceID];
        double unitRate = [_engine.outputNode outputFormatForBus:0].sampleRate;
        unconfirmed = !readFormat ? @"the device's format could not be read"
                : self.varispeed ? @"a varispeed is in the chain"
                : self.fx.masterBusOutputNode ? @"the FX bus is in the chain"
                : !_outputLevelListener || !_outputDeviceListener ? @"a device listener is missing"
                : bound != _preparedDeviceID
                        ? [NSString stringWithFormat:@"the output unit is bound to device %u", bound]
                : !VibePhysicalFormatsEquivalent(physical, _preparedFormat) ? @"the device left the format set on it"
                : mixerFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the mixer runs at %.0f Hz", mixerFormat.sampleRate]
                : outputInputFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the output unit takes %.0f Hz", outputInputFormat.sampleRate]
                : unitRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the output unit runs at %.0f Hz", unitRate]
                : nil;
        report.formatConfirmed = (unconfirmed == nil);
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        report.hogWanted = _exclusiveOutputWanted; // the device is eligible and prepared by here
        pid_t owner = -1;
        report.exclusive = _hoggedDeviceID == _preparedDeviceID
                && [CoreAudioUtil readHogOwner:&owner forDeviceID:_preparedDeviceID] && owner == getpid();
#endif
        AVAudioFile *file = _file; // queue-confined writer; the promoted splice file included
        if (![CoreAudioUtil readOutputVolume:&report.softwareVolume balance:&report.balance mute:&report.muted
                                    channels:file.fileFormat.channelCount inStream:_preparedStreamID
                                 forDeviceID:_preparedDeviceID]) {
            unconfirmed = unconfirmed ?: @"the device's volume could not be read";
            report.formatConfirmed = NO;
        }
        if (file) {
            AudioStreamBasicDescription source = *file.fileFormat.streamDescription;
            // Keep the mixer one-to-one; wider hardware is transparent only
            // when the AU's actual map preserves the prepared stream's pair.
            UInt32 channels = source.mChannelsPerFrame;
            report.channelsMatch = channels > 0
                    && file.processingFormat.channelCount == channels
                    && mixerFormat.channelCount == channels
                    && outputInputFormat.channelCount == channels
                    && [CoreAudioUtil outputUnit:_engine.outputNode.audioUnit preservesChannels:channels
                            inStream:_preparedStreamID physicalChannelCount:physical.mChannelsPerFrame];
            report.rateExact = (physical.mSampleRate == source.mSampleRate);
            report.depthOK = VibePhysicalFormatSatisfies(physical, source,
                                                         *file.processingFormat.streamDescription);
            report.sourceLossless = VibeSourceIsLossless(source);
        }
    }
    os_unfair_lock_lock(&_stateLock);
    report.hasTrack = _bitPerfectWanted && _state == VibePlayerStatePlaying;
    report.status = VibeBitPerfectFold(report);
    BOOL changed = !VibeBitPerfectReportsEqual(_bitPerfectReport, report);
    _bitPerfectReport = report;
    os_unfair_lock_unlock(&_stateLock);
    if (!changed) {
        return;
    }
    if (unconfirmed) {
        LogWarn(@"bit-perfect: format not confirmed, because %@", unconfirmed);
    }
    run_on_main_thread({
        id<AudioPlayerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(audioPlayerDidChangeBitPerfectReport:)]) {
            [delegate audioPlayerDidChangeBitPerfectReport:self];
        }
    });
}


#pragma mark - Diagnostics

// The queue hop is the point: activeOutputDeviceID reads the engine's output
// node, and every other engine touch in the app runs on _queue.
- (NSInteger)currentlyActiveAudioDeviceId {
    __block AudioDeviceID deviceID = kAudioObjectUnknown;
    [self runSyncOnQueue:^{
        deviceID = [self activeOutputDeviceID];
    }];
    return (NSInteger)deviceID;
}

static NSString *VibeBitPerfectStatusName(VibeBitPerfectStatus status) {
    switch (status) {
        case VibeBitPerfectStatusOff:               return @"off";
        case VibeBitPerfectStatusIdle:              return @"idle";
        case VibeBitPerfectStatusActive:            return @"active";
        case VibeBitPerfectStatusRateUnsupported:   return @"rateUnsupported";
        case VibeBitPerfectStatusSwitchFailed:      return @"switchFailed";
        case VibeBitPerfectStatusChannelConversion: return @"channelConversion";
        case VibeBitPerfectStatusDepthInsufficient: return @"depthInsufficient";
        case VibeBitPerfectStatusMuted:             return @"muted";
        case VibeBitPerfectStatusVolumeScaled:      return @"volumeScaled";
        case VibeBitPerfectStatusExclusiveRefused:  return @"exclusiveRefused";
        case VibeBitPerfectStatusSourceLossy:       return @"sourceLossy";
    }
    return @"unknown";
}

- (NSDictionary<NSString *, id> *)bitPerfectReportDictionary {
    VibeBitPerfectReport r = self.bitPerfectReport;
    return @{
        @"enabled": @(r.enabled),
        @"status": VibeBitPerfectStatusName(r.status),
        @"sampleRate": @(r.sampleRate),
        @"bitsPerChannel": @(r.bitsPerChannel),
        @"isFloat": @(r.isFloat),
        @"softwareVolume": @(r.softwareVolume),
        @"balance": @(r.balance),
        @"muted": @(r.muted),
        @"eligibleDevice": @(r.eligibleDevice),
        @"hasTrack": @(r.hasTrack),
        @"rateExact": @(r.rateExact),
        @"formatConfirmed": @(r.formatConfirmed),
        @"depthOK": @(r.depthOK),
        @"channelsMatch": @(r.channelsMatch),
        @"hogWanted": @(r.hogWanted),
        @"exclusive": @(r.exclusive),
        @"sourceLossless": @(r.sourceLossless),
    };
}

@end

#pragma mark - Output devices (public API, declared in AudioPlayer.h)

@implementation AudioPlayer (Devices)

- (void)clearFXIntent {
    // Clear at submission: a queued bypass must not erase newer FX actions.
    self.fx.lowKillBoostActive = NO;
    self.fx.lowKillEnabled = NO;
    self.fx.reverbSendEnabled = NO;
    self.fx.delaySendEnabled = NO;
    self.fx.shortDelaySendEnabled = NO;
}

- (void)setOutputDevice:(NSInteger)outputDeviceID completion:(dispatch_block_t)completion {
    NSString *uid = [AudioDeviceManager.sharedInstance outputDeviceForId:outputDeviceID].uid;
    BOOL bitPerfectOutput = NO, exclusiveOutput = NO;
    [self readOutputModesForDeviceUID:uid bitPerfectOutput:&bitPerfectOutput exclusiveOutput:&exclusiveOutput];
    if (bitPerfectOutput) {
        [self clearFXIntent];
    }
    dispatch_async(_queue, ^{
        // System Output is a policy intent, so it supersedes a saved concrete
        // device even when no output currently exists. Clear before binding to
        // fence a resolver completion already queued behind this selection.
        if (outputDeviceID == -1) {
            self->_pendingSavedDeviceUID = nil;
            self->_pendingSavedDeviceName = nil;
            self->_pendingSavedDeviceModelUID = nil;
        }

        BOOL didBind = [self selectOutputDeviceOnQueue:outputDeviceID];
        if (didBind && outputDeviceID >= 0) {
            // A concrete choice owns the intent only once the HAL accepted it.
            // On failure, Settings still names the saved launch preference, so
            // keep the in-memory pending intent aligned with it.
            self->_pendingSavedDeviceUID = nil;
            self->_pendingSavedDeviceName = nil;
            self->_pendingSavedDeviceModelUID = nil;
        }
        run_on_main_thread({ completion(); });
    });
}

#pragma mark - Bit-perfect output (public, declared in AudioPlayer.h)

- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput enableFX:(BOOL)enableFX {
    if (bitPerfectOutput || !enableFX) {
        [self clearFXIntent];
    }
    dispatch_async(_queue, ^{
        BOOL desiredBitPerfect = bitPerfectOutput, desiredExclusive = exclusiveOutput;
        NSInteger requested = self.currentlyRequestedAudioDeviceId;
        NSString *uid = requested >= 0
                ? [AudioDeviceManager.sharedInstance outputDeviceForId:requested].uid
                : self->_pendingSavedDeviceUID;
        // A global FX edit can queue behind a device switch. Its captured
        // modes belong to the old device, so resolve the queue's current UID.
        [self readOutputModesForDeviceUID:uid bitPerfectOutput:&desiredBitPerfect exclusiveOutput:&desiredExclusive];
        BOOL changed = self->_bitPerfectWanted != desiredBitPerfect
                || (self->_fxEnabled && !self->_bitPerfectWanted) != (enableFX && !desiredBitPerfect);
        self->_fxEnabled = enableFX;
        self->_bitPerfectWanted = desiredBitPerfect;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        changed |= desiredBitPerfect && self->_exclusiveOutputWanted != desiredExclusive;
        self->_exclusiveOutputWanted = desiredExclusive;
#endif
        // Reapplying settings must not interrupt playback. An exclusive
        // preference saved while bit-perfect is off cannot affect the graph.
        if (!changed) {
            return;
        }
        if (desiredBitPerfect) {
            [self resolvePendingSavedOutputDeviceOnQueue];
        }
        // A saved device can be absent at launch. Turning the mode off on
        // System Output must restore varispeed on the current track too.
        AudioDeviceID deviceID = requested >= 0 ? (AudioDeviceID)requested : kAudioObjectUnknown;
        // Rebuild the route even without a resolved device or during an open.
        // A loaded track resumes in place; an open keeps its pending intent.
        [self configureOutputDeviceOnQueue:deviceID];
        [self publishBitPerfectReportOnQueue];
    });
}

- (void)prepareForTermination {
    [self runSyncOnQueue:^{
        // Nothing owed is the off-mode steady state, which quits as it always
        // did. A restore under a running engine strands CoreAudio (error 35).
        if (self->_preparedDeviceID == kAudioObjectUnknown && self->_changedFormatDeviceID == kAudioObjectUnknown
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
                && self->_hoggedDeviceID == kAudioObjectUnknown
#endif
                ) {
            return;
        }
        [self->_engine stop];
        [self leaveOutputDeviceOnQueue];
    }];
}

#if DEBUG
- (NSDictionary<NSString *, NSNumber *> *)debugBitPerfectOwnership {
    __block AudioDeviceID hogged = kAudioObjectUnknown;
    __block AudioDeviceID owed = kAudioObjectUnknown;
    __block AudioDeviceID prepared = kAudioObjectUnknown;
    __block BOOL levelListener = NO, deviceListener = NO;
    __block BOOL varispeed = NO;
    __block double mixerOutputRate = 0, outputNodeInputRate = 0, outputNodeOutputRate = 0;
    [self runSyncOnQueue:^{
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        hogged = self->_hoggedDeviceID;
#endif
        owed = self->_changedFormatDeviceID;
        prepared = self->_preparedDeviceID;
        levelListener = self->_outputLevelListener != nil;
        deviceListener = self->_outputDeviceListener != NULL;
        varispeed = (self.varispeed != nil);
        // The three rates that decide whether the graph resamples: the mixer
        // must feed the output node at the device's own rate.
        mixerOutputRate = [self->_engine.mainMixerNode outputFormatForBus:0].sampleRate;
        outputNodeInputRate = [self->_engine.outputNode inputFormatForBus:0].sampleRate;
        outputNodeOutputRate = [self->_engine.outputNode outputFormatForBus:0].sampleRate;
    }];
    return @{
        @"hoggedDeviceId": @(hogged == kAudioObjectUnknown ? -1 : (NSInteger)hogged),
        @"restoreOwedToDeviceId": @(owed == kAudioObjectUnknown ? -1 : (NSInteger)owed),
        @"preparedDeviceId": @(prepared == kAudioObjectUnknown ? -1 : (NSInteger)prepared),
        @"outputLevelListenerPresent": @(levelListener),
        @"outputDeviceListenerPresent": @(deviceListener),
        @"varispeedPresent": @(varispeed),
        @"mixerOutputRate": @(mixerOutputRate),
        @"outputNodeInputRate": @(outputNodeInputRate),
        @"outputNodeOutputRate": @(outputNodeOutputRate),
    };
}
#endif

@end
