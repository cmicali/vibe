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

// Format changes and restoration wait, with the engine stopped, for the
// device to confirm the write before the graph follows its rate.
static const NSTimeInterval kFormatSwitchDeadlineSeconds = 1.5;
static const useconds_t kFormatSwitchPollMicroseconds = 5000;

// A rebind slower than this held the player queue long enough for the user to
// feel it as a freeze; see #53 and the comment at configureOutputDeviceOnQueue:.
// A bit-perfect switch legitimately reached 0.73s on healthy hardware, so a
// tighter bound would warn about working correctly.
static const NSTimeInterval kSlowDeviceRebindLogThresholdSeconds = 0.25;

#pragma mark - Output devices (internal surface + device-change observing)

@implementation AudioPlayer (DevicesInternal)

// The device that just went away, moved from "bound" to "wanted again". The
// pending slot is the same one a launch preference waits in, so the existing
// resolve path re-adopts the device when it returns — no new mechanism, and
// VibeCanBindSavedOutputDevice still decides when it is safe to bind.
- (void)retainVanishedOutputDeviceIntentOnQueue {
    if (_boundDeviceUID.length == 0 && _boundDeviceName.length == 0) {
        return;
    }
    _pendingSavedDeviceUID = _boundDeviceUID;
    _pendingSavedDeviceModelUID = _boundDeviceModelUID;
    _pendingSavedDeviceName = _boundDeviceName;
    LogInfo(@"AudioPlayer: keeping '%@' as the wanted output device; it vanished rather than being deselected",
            _boundDeviceName.length ? _boundDeviceName : _boundDeviceUID);
}

- (void)systemDefaultOutputDeviceDidChange {
    dispatch_async(_queue, ^{
        if (self->_terminating) return;
        if (self.currentlyRequestedAudioDeviceId == -1) {
            [self setOutputDeviceOnQueue:-1];
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
        [self publishBitPerfectReportOnQueue]; // whether the chosen device is the default moved
    });
}

// The explicitly chosen device disappearing, playing or idle: the manager
// refreshes its snapshot before fanning out, so a vanished device reads as
// absent here. The pending preference survives the fallback until a
// successful re-adoption or an explicit user selection.
- (void)audioOutputDevicesDidChange {
    dispatch_async(_queue, ^{
        if (self->_terminating) return;
        // An unpublished or retrying snapshot is unknown, not removal.
        NSInteger requested = self.currentlyRequestedAudioDeviceId;
        if ([[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:requested]) {
            LogInfo(@"AudioPlayer: requested output device removed; falling back to system default");
            [self abandonBitPerfectForVanishedDeviceOnQueue];
            [self retainVanishedOutputDeviceIntentOnQueue];
            [self setOutputDeviceOnQueue:-1];
        }
        [self resolvePendingSavedOutputDeviceOnQueue];
    });
}

// Read the shared bind rule from queue-owned playback state.
- (BOOL)canBindSavedOutputDeviceNowOnQueue {
    return VibeCanBindSavedOutputDevice(_state == VibePlayerStateStopped,
                                        _state == VibePlayerStateLoading,
                                        _state == VibePlayerStatePaused,
                                        [self renderingOnQueue], _outputAudioActive);
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
    BOOL destinationBitPerfect = NO, destinationExclusive = NO;
    [self readOutputModesForDeviceUID:device.uid bitPerfectOutput:&destinationBitPerfect
                     exclusiveOutput:&destinationExclusive];
    // The store omits disabled modes and removes empty device records.
    if (movedPort && !destinationBitPerfect && !destinationExclusive) {
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
    if (_terminating || _pendingSavedDeviceLookupInFlight
            || (savedUID.length == 0 && savedModelUID.length == 0 && savedName.length == 0)) {
        return;
    }
    // TRAP: returning devices must resolve synchronously, before a local open
    // can move Loading to Playing and make the bind ineligible. Only launch
    // waits for the manager's first successful snapshot.
    AudioDeviceManager *manager = AudioDeviceManager.sharedInstance;
    NSArray<AudioDevice *> *snapshot = manager.cachedOutputDevices;
    if (!snapshot) {
        _pendingSavedDeviceLookupInFlight = YES;
        __weak AudioPlayer *weakSelf = self;
        [manager resolveOutputDeviceForUID:savedUID modelUID:savedModelUID name:savedName
                               completion:^(AudioDevice *device) {
            AudioPlayer *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_queue, ^{
                strongSelf->_pendingSavedDeviceLookupInFlight = NO;
                // Re-read the current intent and snapshot: a manual selection
                // may have superseded the preference while discovery ran.
                [strongSelf resolvePendingSavedOutputDeviceOnQueue];
            });
        }];
        return;
    }
    AudioDevice *device = [AudioDeviceManager deviceForUID:savedUID modelUID:savedModelUID
                                                     name:savedName inDevices:snapshot];
    if (device && ![self canBindSavedOutputDeviceNowOnQueue]) {
        LogInfo(@"AudioPlayer: '%@' is present but playback is audible; adopting it once it is not", device.name);
        return;
    }
    if (!device && !_bitPerfectWanted) return;
    // TRAP: hold the guard across every bind, including cached resolutions.
    // A refused HAL bind publishes Stopped; reset must not queue another try.
    _pendingSavedDeviceLookupInFlight = YES;
    if (device) {
        BOOL bound = [self selectSavedOutputDeviceOnQueue:device savedUID:savedUID savedModelUID:savedModelUID];
        LogInfo(@"AudioPlayer: wanted device '%@' adoption %@ (saved UID %@, found %@)",
                device.name, bound ? @"succeeded" : @"failed; retaining intent", savedUID, device.uid);
        if (bound) {
            _pendingSavedDeviceUID = nil;
            _pendingSavedDeviceName = nil;
            _pendingSavedDeviceModelUID = nil;
        }
    }
    else {
        LogInfo(@"AudioPlayer: saved device '%@' absent; retaining intent while following System Output", savedName);
        [self abandonBitPerfectForVanishedDeviceOnQueue];
        [self setOutputDeviceOnQueue:-1];
    }
    _pendingSavedDeviceLookupInFlight = NO;
}

// The bound device is a field of the hosted unit, never a HAL read, and
// kAudioObjectUnknown only before a first bind that found no device. Without
// a unit — the debug pump — the system default stands in.
- (AudioDeviceID)activeOutputDeviceID {
    if (!_outputUnit) {
        return [CoreAudioUtil systemDefaultOutputDeviceID];
    }
    return _outputUnit.deviceID;
}

// Without a unit — the debug pump — there is nothing to bind, and a selection
// keeps its menu and persistence behaviour.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID {
    return [self performDiagnosticPhase:@"device bind" device:deviceID operation:^BOOL{
        [self stopWatchingBoundDeviceRateOnQueue];
        OSStatus status = self->_outputUnit ? [self->_outputUnit bindToDevice:deviceID] : noErr;
        if (status != noErr) {
            LogError(@"AudioPlayer: could not bind the output unit to device %u (OSStatus %d)", deviceID, (int)status);
            return NO;
        }
        if (self->_outputUnit) {
            [self watchBoundDeviceRateOnQueue:deviceID];
        }
        return YES;
    }];
}

// TRAP: another process moving the bound device's rate — Audio MIDI Setup,
// a DAW, the loopback verifier — leaves the unit configured at the old one,
// and a hosted unit renders nothing at a rate the device no longer runs at
// (measured: silence on BlackHole moved 96 → 48 kHz under a playing unit).
// So the bound device's rate is watched in every mode, and a rate other
// than the pipeline's rebinds in place, which follows the rate and
// re-voices. A prepared bit-perfect device has its own listener, which
// puts the mode's format back instead; Vibe's own rate writes arrive with
// the pipeline already at the rate, a no-op.
- (void)watchBoundDeviceRateOnQueue:(AudioDeviceID)deviceID {
    __weak AudioPlayer *weakSelf = self;
    AudioObjectPropertyListenerBlock listener = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_terminating || strongSelf->_boundRateDeviceID != deviceID
                || strongSelf->_preparedDeviceID == deviceID) {
            return;
        }
        Float64 rate = 0;
        if ([CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID] && rate > 0
                && rate != [strongSelf masterBusFormatOnQueue].sampleRate && ![CoreAudioUtil deviceIsConfirmedDead:deviceID]) {
            LogInfo(@"AudioPlayer: device %u moved to %.0f Hz under the pipeline; rebinding", deviceID, rate);
            [strongSelf configureOutputDeviceOnQueue:kAudioObjectUnknown];
        }
    } copy];
    if ([CoreAudioUtil addNominalRateListener:listener queue:_queue forDeviceID:deviceID]) {
        _boundRateListener = listener;
        _boundRateDeviceID = deviceID;
    }
}

- (void)stopWatchingBoundDeviceRateOnQueue {
    if (_boundRateListener) {
        [CoreAudioUtil removeNominalRateListener:_boundRateListener queue:_queue forDeviceID:_boundRateDeviceID];
        _boundRateListener = nil;
        _boundRateDeviceID = kAudioObjectUnknown;
    }
}

// Whether the standing master-bus route disagrees with the flags: the FX
// segment in the chain while the mode or the setting says not, or absent
// while both say so.
- (BOOL)masterBusRouteStaleOnQueue {
    return self.fx.connected != [self fxWantedOnQueue];
}

// The graph runs at the bound device's rate, so the unit never resamples:
// re-read after every bind; the prepare applies the rate its own format
// write settled on. An unreadable rate keeps the current one.
- (void)followOutputDeviceRateOnQueue {
    Float64 rate = 0;
    if (_outputUnit && [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:_outputUnit.deviceID] && rate > 0) {
        [self applyOutputRateOnQueue:rate];
    }
}

// Rebuilds the graph, restoring the track, position and play or pause state.
// kAudioObjectUnknown keeps the current binding (a mode toggle on System
// Output needs no device read). On failure it reports a delegate error.
// The report is held throughout. A success is published by the caller once
// the requested id is committed — publishing here would fold the old id
// against the new prepared device — so only the failure reset's held
// publication is owed here.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    if (_terminating) return NO;
    _rebindDeviceID = deviceID;
    // The whole rebuild holds the player queue, so every transport action
    // submitted during it waits (#53). A device slow to deliver its first IO
    // cycle can make that seconds. Warn level so it persists and a user can
    // retrieve it with `log show` rather than having to catch it live; the
    // narrower attribution, the engine start's own timing, is AudioPlayer+Graph's.
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

// Park a lost output at its retained intent: the engine stops, which kills
// every retiring voice, and the current voice pauses where it is, to resume
// on whatever device comes back.
- (void)parkPlaybackForMissingOutputDeviceOnQueue {
    if (_state != VibePlayerStatePlaying || !_voice) {
        return;
    }
    [self stopOutputOnQueue];
    [self pauseCurrentVoiceOnQueue];
}

#pragma mark - Output device mutation

- (void)readOutputModesForDeviceUID:(NSString *)deviceUID
                  bitPerfectOutput:(BOOL *)bitPerfectOutput
                   exclusiveOutput:(BOOL *)exclusiveOutput {
    os_unfair_lock_lock(&_stateLock);
    NSString *sourceUID = deviceUID;
    for (NSUInteger remaining = _unpersistedOutputModeSources.count; sourceUID && remaining; remaining--) {
        NSString *carried = _unpersistedOutputModeSources[sourceUID];
        if (!carried) break;
        sourceUID = carried;
    }
    os_unfair_lock_unlock(&_stateLock);
    id<AudioPlayerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(audioPlayer:outputModesForDeviceUID:bitPerfectOutput:exclusiveOutput:)]) {
        [delegate audioPlayer:self outputModesForDeviceUID:(sourceUID ?: deviceUID)
             bitPerfectOutput:bitPerfectOutput exclusiveOutput:exclusiveOutput];
    }
}

- (BOOL)selectOutputDeviceOnQueue:(NSInteger)outputDeviceID {
    if (_terminating) return NO;
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
            [self stopOutputOnQueue];
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
    NSTimeInterval teardownS = 0, leaveS = 0, bindS = 0, restoreS = 0, startS = 0;
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
    BOOL wasPlaying = shouldRestore && !intent.paused;

    // Nothing is audible across a rebind: the engine stops, which kills every
    // retiring voice, and the current voice keeps its ring and gain for the
    // restart. Drop the display/FFT activity now, before a potentially slow
    // HAL rebind, rather than waiting for the final restored state.
    [self stopOutputOnQueue];
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
    [self followOutputDeviceRateOnQueue];
    [self reconcileFXOnQueue];
    VIBE_REBIND_PHASE(bindS);

    if (shouldRestore) {
        // Reuse the already-open handle rather than reopening the URL. A
        // synchronous, timeout-free initForReading: here would wedge the whole
        // queue if the track had been evicted to an iCloud or Dropbox
        // placeholder, or sat on a hung mount, between the play and the device
        // switch. processingFormat is fixed at open, so a new voice on the
        // existing file is safe.
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
        // The source segment follows the mode and the file's format; a
        // rebuild kills the current voice and the reconcile starts it again
        // at the retained intent, so the voice either survived, ring and all,
        // or stands replaced where it was.
        if (![self reconcileSourceSegmentOnQueue]) {
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        VIBE_REBIND_PHASE(restoreS);
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startOutputOnQueue:&startError]) {
                // No output to restart on. Park Paused at the same position,
                // so the next resume restarts the engine, and say why.
                [self pauseCurrentVoiceOnQueue];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not restart playback on the new audio device", startError)];
                return NO;
            }
            [self armSignalProbeOnQueue:@"device rebind"];
        }
        else {
            [self scheduleOutputIdleStopOnQueue];
        }
        [self maybeArmSuccessorOnQueue]; // re-queue the successor behind the restored voice
    }
    VIBE_REBIND_PHASE(startS);

    NSTimeInterval total = teardownS + leaveS + bindS + restoreS + startS;
    if (total > kSlowDeviceRebindLogThresholdSeconds) {
        LogWarn(@"AudioPlayer: slow rebind to %u, %.3fs total — teardown %.3f, "
                @"leave/restore-format %.3f, bind+graph %.3f, reschedule %.3f, "
                @"engine start %.3f", deviceID, total, teardownS, leaveS, bindS,
                restoreS, startS);
    }
    return YES;
}
#undef VIBE_REBIND_PHASE

- (BOOL)setOutputDeviceOnQueue:(NSInteger)outputDeviceID {
    if (_terminating) return NO;

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

    // Choosing the device already bound can still change the graph: a wanted
    // mode newly eligible prepares the current track, and a destination that
    // wants the mode off on the same hardware restores its format and the FX
    // route. The unit does not move for either.
    BOOL needsPreparation = (_bitPerfectWanted
            ? outputDeviceID >= 0 && _preparedDeviceID != newDeviceID
            : (_voiceBus && ![self varispeedPresentOnQueue]) || _preparedDeviceID != kAudioObjectUnknown)
            || [self masterBusRouteStaleOnQueue];
    if (newDeviceID != currentDeviceID || needsPreparation) {
        if (![self configureOutputDeviceOnQueue:newDeviceID]) {
            // configureOutputDeviceOnQueue has already reported the error.
            // Do not record or persist a device we failed to switch to.
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
    else {
        // A vanished preference lives in the pending slot now.
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
    // Captured by value: the announcement lands on main asynchronously while
    // the caller clears the queue-side fields straight after.
    NSString *fallbackUID = requested == -1 ? _pendingSavedDeviceUID : nil;
    NSString *fallbackName = requested == -1 ? _pendingSavedDeviceName : nil;
    NSString *modesUID = requested >= 0 ? _modesUIDForNextSelection : nil;
    NSString *destinationUID = _boundDeviceUID;
    if (modesUID.length && destinationUID.length) {
        os_unfair_lock_lock(&_stateLock);
        if (!_unpersistedOutputModeSources) _unpersistedOutputModeSources = [NSMutableDictionary dictionary];
        _unpersistedOutputModeSources[destinationUID] = modesUID;
        os_unfair_lock_unlock(&_stateLock);
    }
    run_on_main_thread({
        [self.delegate audioPlayer:self didChangeOutputDevice:requested involuntaryFallbackUID:fallbackUID
            involuntaryFallbackName:fallbackName carriedModesFromUID:modesUID];
        if (modesUID.length && destinationUID.length) {
            os_unfair_lock_lock(&self->_stateLock);
            if ([self->_unpersistedOutputModeSources[destinationUID] isEqual:modesUID]) {
                [self->_unpersistedOutputModeSources removeObjectForKey:destinationUID];
            }
            os_unfair_lock_unlock(&self->_stateLock);
        }
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
// must not); the unit's own device would name the one the switch is leaving.
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
    if (!_bitPerfectWanted || !_outputUnit) {
        return nil; // off, or the debug pump, which has no device to prepare
    }
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

- (BOOL)outputNeedsSwitchOnQueueForFile:(AVAudioFile *)file {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    if (!device) {
        return NO;
    }
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription current = {0}, chosen = {0};
    if (![self resolveOutputFormatOnQueueForFile:file device:device stream:&stream
                                         current:&current chosen:&chosen]) {
        return YES; // unknown compatibility cannot splice
    }
    double mixerRate = [self masterBusFormatOnQueue].sampleRate;
    BOOL needsSwitch = VibeBitPerfectOutputNeedsSwitch(current, chosen, mixerRate);
#if VIBE_VERBOSE_LOGGING
    if (needsSwitch) {
        LogInfo(@"bit-perfect: %@ needs a switch: device %.0f Hz %u-bit flags 0x%x %u bytes/frame, chosen %.0f Hz %u-bit flags 0x%x %u bytes/frame, bus %.0f Hz",
                file.url.lastPathComponent, current.mSampleRate, (unsigned)current.mBitsPerChannel,
                (unsigned)current.mFormatFlags, (unsigned)current.mBytesPerFrame, chosen.mSampleRate,
                (unsigned)chosen.mBitsPerChannel, (unsigned)chosen.mFormatFlags, (unsigned)chosen.mBytesPerFrame, mixerRate);
    }
#endif
    return needsSwitch;
}

- (BOOL)decodesAsInteger16OnQueueForFile:(AVAudioFile *)file {
    return _bitPerfectWanted && file && _preparedDeviceID != kAudioObjectUnknown
            && VibeBitPerfectDecodesAsInteger16(*file.fileFormat.streamDescription, _preparedFormat);
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
    [self stopOutputOnQueue];
    [self leaveOutputDeviceOnQueue];
    // The source segment follows the mode at the next settlement or rebind.
    [self publishBitPerfectReportOnQueue];
}

- (BOOL)setOutputFormatOnQueue:(AudioStreamBasicDescription)format
                       stream:(AudioStreamID)stream device:(AudioDeviceID)deviceID {
    return [self performDiagnosticPhase:@"format write/confirmation" device:deviceID operation:^BOOL{
        return [self confirmOutputFormatOnQueue:format stream:stream device:deviceID];
    }];
}

- (BOOL)confirmOutputFormatOnQueue:(AudioStreamBasicDescription)format
                           stream:(AudioStreamID)stream device:(AudioDeviceID)deviceID {
    if (![CoreAudioUtil setPhysicalFormat:format forStream:stream]) {
        return NO;
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kFormatSwitchDeadlineSeconds;
    // TRAP: an accepted write precedes the nominal rate, so both are confirmed
    // before the graph follows the rate; a restoration must confirm the full
    // sample representation too, including packing.
    do {
        AudioStreamBasicDescription current = {0};
        Float64 rate = 0;
        if ([CoreAudioUtil readPhysicalFormat:&current forStream:stream]
                && VibePhysicalFormatsEquivalent(current, format)
                && [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                && rate == format.mSampleRate) {
            return YES;
        }
        usleep(kFormatSwitchPollMicroseconds);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    LogWarn(@"bit-perfect: format confirmation deadline expired on device %u", deviceID);
    return NO;
}

- (void)prepareOutputOnQueueForFile:(AVAudioFile *)file {
    [self performDiagnosticPhase:@"output preparation" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
        [self prepareOutputFormatOnQueueForFile:file];
        return YES; // confirmation failures are reported by the nested format phase
    }];
}

- (void)prepareOutputFormatOnQueueForFile:(AVAudioFile *)file {
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
    if (VibeBitPerfectOutputNeedsSwitch(current, chosen, [self masterBusFormatOnQueue].sampleRate)) {
        // Bit-perfect edges are cuts or declicks, so a settlement mid-fade
        // loses at most a declick; the device restore stopped the engine itself.
        [self stopOutputOnQueue];
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
    // The pipeline follows the device: the bus, the FX segment and the unit
    // all run at its rate, so nothing resamples.
    if (current.mSampleRate > 0 && current.mSampleRate != [self masterBusFormatOnQueue].sampleRate) {
        [self applyOutputRateOnQueue:current.mSampleRate];
    }
}

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
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
    // Taking the device that is the system default moves the default elsewhere;
    // the hosted unit stays bound and nothing here waits for anything.
    // A successful write followed by a failed read-back may still own the
    // device. Record the cleanup obligation BEFORE asking the HAL to take it.
    _hoggedDeviceID = deviceID;
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Phase: play %llu voice %llu exclusive context: requested %ld, bound %u",
            [self diagnosticPlayIdentifierOnQueue], _voice,
            (long)self.currentlyRequestedAudioDeviceId, [self activeOutputDeviceID]);
#endif
    if (![self performDiagnosticPhase:@"hog acquire" device:deviceID operation:^BOOL{
        return [CoreAudioUtil setHogOwnedByThisProcess:YES forDeviceID:deviceID];
    }]) {
        LogWarn(@"bit-perfect: could not confirm exclusive access to %@", device.name);
        [self releaseExclusiveOutputOnQueue]; // publishes
        return;
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
        return [self performDiagnosticPhase:@"hog release" device:self->_hoggedDeviceID operation:^BOOL{
            return [CoreAudioUtil setHogOwnedByThisProcess:NO forDeviceID:self->_hoggedDeviceID];
        }];
    } isAbsent:^BOOL(AudioDeviceID deviceID) {
        return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:deviceID];
    }];
    if (_hoggedDeviceID != kAudioObjectUnknown) {
        LogWarn(@"bit-perfect: release still owed to device %u", _hoggedDeviceID);
    }
    [self publishBitPerfectReportOnQueue];
}

#endif

// Watch the prepared device's volume, balance, mute and nominal rate.
// kAudioObjectUnknown removes the listener. Copy the HAL block before adding
// it, because removal must receive the same block object.
- (BOOL)setPreparedDeviceOnQueue:(AudioDeviceID)deviceID {
    if (_preparedDeviceID == deviceID && (_outputLevelListener || deviceID == kAudioObjectUnknown)) {
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
    AudioObjectPropertyListenerBlock listener = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_bitPerfectWanted && strongSelf->_preparedDeviceID == deviceID) {
            for (UInt32 i = 0; i < count; i++) {
                AudioObjectPropertySelector selector = addresses[i].mSelector;
#if VIBE_VERBOSE_LOGGING
                LogInfo(@"Callback: bit-perfect device listener, '%c%c%c%c' changed on device %u", (char)(selector >> 24),
                        (char)(selector >> 16), (char)(selector >> 8), (char)selector, deviceID);
#endif
                if (selector == kAudioDevicePropertyNominalSampleRate) {
                    // Another process moved the prepared device's rate: the
                    // rebind's prepare sets the mode's format back. Vibe's own
                    // writes arrive with the graph already at the rate, a
                    // no-op; a vanished device is the device-list observer's.
                    Float64 rate = 0;
                    if ([CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                            && rate != [strongSelf masterBusFormatOnQueue].sampleRate
                            && ![CoreAudioUtil deviceIsConfirmedDead:deviceID]) {
                        LogInfo(@"bit-perfect: device %u moved to %.0f Hz under the graph; rebinding", deviceID, rate);
                        [strongSelf configureOutputDeviceOnQueue:deviceID];
                        [strongSelf publishBitPerfectReportOnQueue];
                    }
                    break;
                }
                if (selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                        || selector == kAudioHardwareServiceDeviceProperty_VirtualMainBalance
                        || selector == kAudioDevicePropertyVolumeScalar
                        || selector == kAudioDevicePropertyVolumeDecibels
                        || selector == kAudioDevicePropertyStereoPan
                        || selector == kAudioDevicePropertyMute
                        || selector == kAudioObjectPropertySelectorWildcard) {
                    strongSelf->_outputControlsDeviceID = kAudioObjectUnknown;
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
            _outputControlsDeviceID = kAudioObjectUnknown; // changes while unwatched were missed
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
    [self reconcileFXOnQueue];
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
    BOOL controlsCached = NO;
#if VIBE_VERBOSE_LOGGING
    BOOL readDevice = NO;
    uint64_t readStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif
    report.enabled = _bitPerfectWanted;
    AudioDevice *device = _bitPerfectWanted ? [self eligibleRequestedDeviceOnQueue] : nil;
    report.eligibleDevice = (device != nil);
    if (device && (AudioDeviceID)device.deviceId == _preparedDeviceID) {
#if VIBE_VERBOSE_LOGGING
        readDevice = YES;
#endif
        AudioStreamBasicDescription physical = {0};
        BOOL readFormat = [CoreAudioUtil readPhysicalFormat:&physical forStream:_preparedStreamID];
        AVAudioFormat *mixerFormat = [self masterBusFormatOnQueue];
        AVAudioFormat *unitFormat = _outputUnit.format;
        report.sampleRate = physical.mSampleRate;
        report.bitsPerChannel = physical.mBitsPerChannel;
        report.isFloat = VibePhysicalFormatIsFloat(physical);
        // Named rather than folded into one flag: "switch failed" alone sent #47
        // round the houses, and the debug info log is where this is read.
        AudioDeviceID bound = [self activeOutputDeviceID];
        unconfirmed = !readFormat ? @"the device's format could not be read"
                : [self varispeedPresentOnQueue] ? @"a varispeed is in the chain"
                : self.fx.connected ? @"the FX bus is in the chain"
                : !_outputLevelListener ? @"the device listener is missing"
                : bound != _preparedDeviceID
                        ? [NSString stringWithFormat:@"the output unit is bound to device %u", bound]
                : !VibePhysicalFormatsEquivalent(physical, _preparedFormat) ? @"the device left the format set on it"
                : mixerFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the bus runs at %.0f Hz", mixerFormat.sampleRate]
                : unitFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the output unit pulls at %.0f Hz", unitFormat.sampleRate]
                : nil;
        report.formatConfirmed = (unconfirmed == nil);
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        report.hogWanted = _exclusiveOutputWanted; // the device is eligible and prepared by here
        pid_t owner = -1;
        report.exclusive = _hoggedDeviceID == _preparedDeviceID
                && [CoreAudioUtil readHogOwner:&owner forDeviceID:_preparedDeviceID] && owner == getpid();
#endif
        AVAudioFile *file = _file; // queue-confined writer; the promoted splice file included
        UInt32 controlChannels = file.fileFormat.channelCount;
        // No file (Loading) asks for no channels; the last track's reading covers it.
        controlsCached = _outputLevelListener && _outputControlsDeviceID == _preparedDeviceID
                && _outputControlsStreamID == _preparedStreamID
                && (_outputControlsChannels == controlChannels || controlChannels == 0);
        if (!controlsCached) {
            BOOL read = [CoreAudioUtil readOutputVolume:&_outputControlsVolume balance:&_outputControlsBalance
                                                   mute:&_outputControlsMuted channels:controlChannels
                                               inStream:_preparedStreamID forDeviceID:_preparedDeviceID];
            // A failed read is never kept, so the next publication tries again.
            _outputControlsDeviceID = read ? _preparedDeviceID : kAudioObjectUnknown;
            _outputControlsStreamID = _preparedStreamID;
            _outputControlsChannels = controlChannels;
        }
        report.softwareVolume = _outputControlsVolume;
        report.balance = _outputControlsBalance;
        report.muted = _outputControlsMuted;
        if (_outputControlsDeviceID != _preparedDeviceID) {
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
                    && unitFormat.channelCount == channels
                    && [CoreAudioUtil outputUnit:_outputUnit.audioUnit preservesChannels:channels
                            inStream:_preparedStreamID physicalChannelCount:physical.mChannelsPerFrame];
            report.rateExact = (physical.mSampleRate == source.mSampleRate);
            report.depthOK = VibePhysicalFormatSatisfies(physical, source,
                                                         *file.processingFormat.streamDescription);
            report.sourceLossless = VibeSourceIsLossless(source);
        }
    }
#if VIBE_VERBOSE_LOGGING
    // Every state publication and fade completion lands here, on the player
    // queue, so a slow device read delays the next transport action by as much.
    double readMilliseconds = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - readStarted) / 1e6;
    if (readDevice && (readMilliseconds >= 2 || !controlsCached)) {
        LogInfo(@"bit-perfect: report read device %u for %.1f ms (volume/balance/mute %@)",
                _preparedDeviceID, readMilliseconds, controlsCached ? @"cached" : @"read from the device");
    }
#endif
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

// "44100 Hz i16 interleaved 2ch": what the current voice decodes its file to.
static NSString *VibeFormatText(AVAudioFormat *format) {
    if (!format) {
        return @"";
    }
    NSString *sample = format.commonFormat == AVAudioPCMFormatInt16 ? @"i16"
            : format.commonFormat == AVAudioPCMFormatInt32 ? @"i32"
            : format.commonFormat == AVAudioPCMFormatFloat32 ? @"f32"
            : format.commonFormat == AVAudioPCMFormatFloat64 ? @"f64" : @"other";
    return [NSString stringWithFormat:@"%.0f Hz %@%@ %uch", format.sampleRate, sample,
            format.interleaved ? @" interleaved" : @"", (unsigned)format.channelCount];
}

- (NSDictionary<NSString *, id> *)outputDeviceDiagnosticSnapshot {
    __block NSDictionary *snapshot;
    [self runSyncOnQueue:^{
        snapshot = @{
            @"decodeFormat": VibeFormatText(self->_decodeFormat),
            @"boundOutputDeviceId": @([self activeOutputDeviceID]),
            @"requestedOutputDeviceId": @(self.currentlyRequestedAudioDeviceId),
            @"pendingDeviceUID": self->_pendingSavedDeviceUID ?: @"",
            @"pendingDeviceModelUID": self->_pendingSavedDeviceModelUID ?: @"",
            @"pendingDeviceName": self->_pendingSavedDeviceName ?: @"",
            @"savedDeviceLookupInFlight": @(self->_pendingSavedDeviceLookupInFlight),
            @"bitPerfectWanted": @(self->_bitPerfectWanted),
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
            @"exclusiveOutputWanted": @(self->_exclusiveOutputWanted),
            @"hoggedDeviceId": @(self->_hoggedDeviceID == kAudioObjectUnknown ? -1 : (NSInteger)self->_hoggedDeviceID),
#endif
            @"restoreOwedToDeviceId": @(self->_changedFormatDeviceID == kAudioObjectUnknown ? -1 : (NSInteger)self->_changedFormatDeviceID),
            @"preparedDeviceId": @(self->_preparedDeviceID == kAudioObjectUnknown ? -1 : (NSInteger)self->_preparedDeviceID),
            @"outputLevelListenerPresent": @(self->_outputLevelListener != nil),
            @"varispeedPresent": @([self varispeedPresentOnQueue]),
            @"busRate": @([self masterBusFormatOnQueue].sampleRate),
            @"outputUnitRate": @(self->_outputUnit.format.sampleRate),
            @"outputUnitRunning": @(self->_outputUnit.running),
            @"outputDropouts": @(self->_outputUnit.dropouts),
            @"presentationLatency": @(self->_outputUnit.presentationLatency),
            @"outputRunning": @([self renderingOnQueue]),
            @"terminating": @(self->_terminating),
            @"activeSubmittedPlayIdentifier": @(self->_activeSubmittedPlayIdentifier),
            @"voice": @(self->_voice),
        };
    }];
    return snapshot;
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
        if (self->_terminating) return;
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
        // Stop owns the open and prefetch cancellation; _terminating closes
        // admission first so nothing queued behind can restart the engine.
        self->_terminating = YES;
        [self stopOnQueue];
        [self stopOutputOnQueue];
        [self leaveOutputDeviceOnQueue];
        LogInfo(@"AudioPlayer: termination cleanup complete");
    }];
}

@end
