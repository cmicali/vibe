//
//  AudioPlayer+Devices.m
//  Vibe
//

#import "AudioPlayer+Devices.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "AudioFX.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <AudioToolbox/AudioToolbox.h>

static const NSTimeInterval kSystemOutputBindRetryDelay = 2.0;

// A rebind slower than this holds the player queue long enough to feel like a
// freeze.
static const NSTimeInterval kSlowDeviceRebindLogThresholdSeconds = 0.25;

@implementation AudioPlayer (PlatformOutput)

- (NSArray<NSDictionary<NSString *, id> *> *)outputUnitAudioPathOnQueue {
    NSMutableDictionary *output = [NSMutableDictionary dictionary];
    if (_outputUnit) {
        output[@"deviceId"] = @(_outputUnit.deviceID == kAudioObjectUnknown ? -1 : (NSInteger)_outputUnit.deviceID);
    }
    AudioDeviceID deviceID = _outputUnit ? _outputUnit.deviceID : kAudioObjectUnknown;
    NSMutableDictionary *device = [@{@"stage": @"device", @"present": @(deviceID != kAudioObjectUnknown)} mutableCopy];
    if (deviceID != kAudioObjectUnknown) {
        AudioDevice *known = [AudioDeviceManager.sharedInstance outputDeviceForId:deviceID];
        __block Float64 rate = 0;
        __block AudioStreamBasicDescription physical = {0};
        __block BOOL rateRead = NO, physicalRead = NO;
        BOOL answered = [CoreAudioUtil performBoundedRead:^{
            AudioStreamID stream = kAudioObjectUnknown;
            rateRead = [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID];
            physicalRead = [CoreAudioUtil readOutputStream:&stream physicalFormat:&physical availableFormats:NULL
                                                     count:NULL forDeviceID:deviceID];
        } within:kDeviceReadWaitSeconds late:nil];
        device[@"deviceId"] = @((NSInteger)deviceID);
        if (known) device[@"name"] = known.name;
        if (known) device[@"uid"] = known.uid;
        if (!answered) device[@"deviceReadTimedOut"] = @YES;
        if (answered && rateRead) device[@"nominalSampleRate"] = @(rate);
        if (answered && physicalRead) {
            device[@"physicalSampleRate"] = @(physical.mSampleRate);
            device[@"physicalBitsPerChannel"] = @(physical.mBitsPerChannel);
            device[@"physicalFloat"] = @((physical.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
            device[@"physicalChannels"] = @(physical.mChannelsPerFrame); // the stream's, of which the unit drives `channels`
        }
        device[@"channels"] = @(_outputUnit.format.channelCount); // what reaches the device: the unit's stereo pair on its channel map
        device[@"latencySeconds"] = @(_outputUnit.presentationLatency); // the device's own: its latency, safety offset and stream latency
        device[@"preparedForBitPerfect"] = @(_preparedDeviceID == deviceID);
        device[@"exclusive"] = @(_hoggedDeviceID == deviceID);
        device[@"bitPerfect"] = [self bitPerfectReportDictionary];
    }
    return @[output, device];
}

- (void)prepareOutputOnQueue {
    [self createOutputUnitOnQueue];
    if (!_masterFormat) {
        [self setMasterBusFormatOnQueue:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2]];
    }
}

- (BOOL)startOutputUnitOnQueueWithError:(NSError **)error {
    if (!_outputUnit) {
        if (error) *error = VibeAudioError(VibeAudioErrorEngineStartFailed, @"No audio output is available", nil);
        return NO;
    }
    if (_boundDeviceHeldElsewhere) {
        if (error) *error = VibeAudioError(VibeAudioErrorDeviceInUse,
                                           @"Another app has exclusive use of the audio output device", nil);
        return NO;
    }
    [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
        [self acquireExclusiveOutputOnQueue];
        return YES;
    }];
    [_outputUnit start]; // a refusal arrives later, at outputUnitFailedOnQueue:
    return YES;
}

- (void)releaseIdleOutputUnitOnQueue {
    [self releaseExclusiveOutputOnQueue];
}
- (BOOL)adoptOutputFormatOnQueue:(AVAudioFormat *)format {
    return [self applyOutputRateOnQueue:format.sampleRate];
}
- (BOOL)followOutputRateOnQueue {
    [self ensureOutputUnitOnQueue]; // a missing unit is the start's to report
    return YES;
}

@end

#pragma mark - Output devices (internal surface + device-change observing)

@implementation AudioPlayer (DevicesInternal)

- (BOOL)createOutputUnitOnQueue {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    if (!unit) {
        LogError(@"AudioPlayer: no HAL output unit; nothing will play until one can be made");
        return NO;
    }
    [self attachOutputUnitOnQueue:unit];
    AudioDeviceID deviceID = kAudioObjectUnknown;
    if ([CoreAudioUtil readSystemDefaultOutputDeviceID:&deviceID] && deviceID != kAudioObjectUnknown) {
        [self setOutputUnitDevice:deviceID];
    }
    [self followOutputDeviceRateOnQueue];
    [[AudioDeviceManager sharedInstance] addObserver:self];
    // First-use HAL discovery stays off the player queue: the output starts
    // on System Output, and the async snapshot applies the saved preference.
    [self resolvePendingSavedOutputDeviceOnQueue];
    return YES;
}

- (BOOL)ensureOutputUnitOnQueue {
    if (_outputUnit || ![self drivesOutputDeviceOnQueue]) {
        return YES;
    }
    AVAudioFormat *before = _masterFormat;
    if (![self createOutputUnitOnQueue]) {
        return NO;
    }
    // TRAP: applyOutputRateOnQueue: leaves the source segment to its caller.
    // A segment built at the fallback format must be reconciled here, or its
    // voice plays at the old rate into the new one.
    if (before && _masterFormat && !VibePCMFormatsMatch(before, _masterFormat) && ![self reconcileSourceSegmentOnQueue]) {
        return NO;
    }
    return YES;
}

- (BOOL)applyOutputRateOnQueue:(double)rate {
    if (!_outputUnit) {
        return NO;
    }
    if (_masterFormat.sampleRate == rate && _outputUnit.format.sampleRate == rate) {
        return YES;
    }
    [self stopOutputOnQueue];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    [_outputUnit configureFormat:format renderProc:VibeMasterBusRender refCon:_masterBus];
    [self setMasterBusFormatOnQueue:format];
    // TRAP: the segment stays at the old rate for the caller to reconcile,
    // which re-voices when it rebuilds. Rebuilt here, the caller's reconcile
    // would find it already at the rate and never start the replacement voice:
    // silence while Playing.
    LogInfo(@"AudioPlayer: output unit pulls at %.0f Hz from device %u", rate, _outputUnit.deviceID);
    return YES;
}

// The device that just went away, moved from "bound" to "wanted again": the
// pending slot a launch preference waits in, so the resolver re-adopts it when
// it returns, whenever VibeCanBindSavedOutputDevice allows.
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

- (BOOL)canBindSavedOutputDeviceNowOnQueue {
    return VibeCanBindSavedOutputDevice(_state == VibePlayerStateStopped,
                                        _state == VibePlayerStateLoading,
                                        _state == VibePlayerStatePaused,
                                        [self renderingOnQueue], _outputAudioActive);
}

// Binds a wanted device the resolver found. A model-UID match under a NEW
// device UID — a class-compliant interface on another USB port — reads the
// modes remembered under the old UID, so the device comes back as the user
// left it. Only a model match earns that (see selectOutputDeviceOnQueue:).
// The shell persists the carry on main.
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
    // TRAP: resolve synchronously, before a local open can move Loading to
    // Playing and make the bind ineligible. Only launch waits for the
    // manager's first snapshot.
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
    // TRAP: hold the guard across every bind, cached resolutions included: a
    // refused bind resets to Stopped, and the reset must not queue another try.
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
// kAudioObjectUnknown before a successful bind or after a bind failure. Without
// a unit — the debug pump — the system default stands in.
- (AudioDeviceID)activeOutputDeviceID {
    if (!_outputUnit) {
        return [CoreAudioUtil systemDefaultOutputDeviceID];
    }
    return _outputUnit.deviceID;
}

// Without a unit — the debug pump — there is nothing to bind, and a selection
// keeps its menu and persistence behaviour. Refused at once only for a device
// the snapshot knows is gone, never on a HAL read; any other refusal lands on
// the unit's queue and fails the next start.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID {
    [self stopWatchingBoundDeviceOnQueue];
    if (!_outputUnit) {
        return YES;
    }
    if ([AudioDeviceManager.sharedInstance knowsOutputDeviceIsAbsent:deviceID]) {
        LogError(@"AudioPlayer: not binding the output unit to device %u, which is gone", deviceID);
        return NO;
    }
    [_outputUnit bindToDevice:deviceID];
    [self watchBoundDeviceOnQueue:deviceID];
    return YES;
}

// TRAP: a hosted unit left at a rate its device no longer runs at renders
// nothing (measured). Another process can move the bound device's rate, so it
// is watched in every mode, and a rate other than the pipeline's rebinds in
// place, following it. A prepared bit-perfect device's own listener puts the
// mode's format back instead; Vibe's own writes arrive with the pipeline
// already at the rate, a no-op. Its hog owner rides the same listener. Both
// are read off the player queue.
- (void)watchBoundDeviceOnQueue:(AudioDeviceID)deviceID {
    __weak AudioPlayer *weakSelf = self;
    AudioObjectPropertyListenerBlock listener = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        __block Float64 rate = 0;
        __block BOOL alive = NO, held = NO;
        dispatch_block_t follow = ^{
            if (alive) [weakSelf followBoundDevice:deviceID toRate:rate heldElsewhere:held];
        };
        if ([CoreAudioUtil performBoundedRead:^{
            alive = [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                    && ![CoreAudioUtil deviceIsConfirmedDead:deviceID];
            held = alive && [CoreAudioUtil deviceIsHeldByAnotherProcess:deviceID];
        } within:0 late:follow]) {
            follow();
        }
    } copy];
    if ([CoreAudioUtil addBoundDeviceListener:listener queue:_queue forDeviceID:deviceID]) {
        _boundDeviceListener = listener;
        _boundDeviceListenerDeviceID = deviceID;
    }
}

- (void)stopWatchingBoundDeviceOnQueue {
    if (_boundDeviceListener) {
        [CoreAudioUtil removeBoundDeviceListener:_boundDeviceListener queue:_queue forDeviceID:_boundDeviceListenerDeviceID];
        _boundDeviceListener = nil;
        _boundDeviceListenerDeviceID = kAudioObjectUnknown;
    }
    _boundDeviceHeldElsewhere = NO;
}

// Whether the standing master-bus route disagrees with the flags: the FX
// segment in the chain while the mode or the setting says not, or absent
// while both say so.
- (BOOL)masterBusRouteStaleOnQueue {
    return self.fx.connected != [self fxWantedOnQueue];
}

// The graph runs at the bound device's rate, so the unit never resamples:
// re-read after every bind; the prepare applies the rate its own format
// write settled on. An unreadable rate keeps the current one. TRAP: the one
// device read ordinary playback waits for, since the pipeline cannot be built
// without it, so it is bounded: a device that answers late keeps the current
// rate, and its answer is then followed as the rate listener's is.
- (void)followOutputDeviceRateOnQueue {
    if (!_outputUnit) {
        return;
    }
    AudioDeviceID deviceID = _outputUnit.deviceID;
    __block Float64 rate = 0;
    __block BOOL read = NO, held = NO;
    __weak AudioPlayer *weakSelf = self;
    if (![CoreAudioUtil performBoundedRead:^{
            read = [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID];
            held = [CoreAudioUtil deviceIsHeldByAnotherProcess:deviceID];
        }
                                    within:kDeviceReadWaitSeconds
                                      late:^{ [weakSelf followBoundDevice:deviceID toRate:(read ? rate : 0) heldElsewhere:held]; }]) {
        LogWarn(@"AudioPlayer: device %u did not report its rate within %.0f ms; the pipeline stays at %.0f Hz",
                deviceID, kDeviceReadWaitSeconds * 1000, _masterFormat.sampleRate);
        return;
    }
    _boundDeviceHeldElsewhere = held;
    if (read && rate > 0) {
        [self applyOutputRateOnQueue:rate];
    }
}

// Any thread: a rate and hog owner read off the player queue, for the device
// the unit is bound to when the queue gets it; a rate of 0 is unread. TRAP: a
// foreign hog neither stops the unit nor reports it (IsRunning stays 1,
// measured); the IO simply stops, so unanswered the transport reads Playing
// over a frozen position for as long as the other app holds the device. It
// parks rather than waiting it out: audio must not restart on its own when
// the other app lets go.
- (void)followBoundDevice:(AudioDeviceID)deviceID toRate:(Float64)rate heldElsewhere:(BOOL)held {
    dispatch_async(_queue, ^{
        if (self->_terminating || self->_outputUnit.deviceID != deviceID) {
            return;
        }
        if (held != self->_boundDeviceHeldElsewhere) {
            self->_boundDeviceHeldElsewhere = held;
            LogWarn(@"AudioPlayer: device %u %@ by another process", deviceID, held ? @"taken" : @"released");
            if (held && self->_state == VibePlayerStatePlaying) {
                [self parkPlaybackForMissingOutputDeviceOnQueue];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceInUse,
                        @"Another app took exclusive use of the audio output device", nil)];
            }
            else if (held) {
                [self stopOutputOnQueue]; // a Loading settlement's start then refuses
            }
        }
        if (rate <= 0 || self->_preparedDeviceID == deviceID || rate == [self masterBusFormatOnQueue].sampleRate) {
            return;
        }
        LogInfo(@"AudioPlayer: device %u moved to %.0f Hz under the pipeline; rebinding", deviceID, rate);
        [self configureOutputDeviceOnQueue:kAudioObjectUnknown];
    });
}

// Rebuilds the graph, restoring the track, position and play or pause state.
// kAudioObjectUnknown keeps the current binding. On failure it reports a
// delegate error. The report is held throughout: the caller publishes a
// success once the requested id is committed — publishing here would fold the
// old id against the new prepared device — so only a failure publishes here.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    if (_terminating) return NO;
    _rebindDeviceID = deviceID;
    // The device's own time is the output unit's, off this queue.
    // A phase because the rebind stops the output first: without one the
    // queue stall watcher parks, and a slow rebind holds plays unsampled.
    uint64_t reboundAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL rebound = [self performDiagnosticPhase:@"device rebind" device:deviceID operation:^BOOL{
        return [self rebindOutputOnQueueToDevice:deviceID];
    }];
    NSTimeInterval seconds =
            (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - reboundAt) / NSEC_PER_SEC;
    BOOL slowRebind = seconds > kSlowDeviceRebindLogThresholdSeconds;
    LogTiming(slowRebind, @"AudioPlayer: %@device rebind to %u took %.3fs (%@)",
            slowRebind ? @"slow " : @"", deviceID, seconds, rebound ? @"bound" : @"FAILED");
    _rebindDeviceID = kAudioObjectUnknown;
    if (!rebound) {
        // Preserve callers of a synchronous rebuild failure for symbolication.
        // Asynchronous HAL refusals arrive through outputUnitFailedOnQueue:.
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

// Park a lost output at its retained intent: the output stops, which kills
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
    // TRAP: a name fallback can resolve different hardware; read the
    // destination's own modes before preparing or hogging it, never the
    // missing device's, or exclusive hogs a device the user never enabled it
    // on. The one exception is _modesUIDForNextSelection, set only for a
    // model-UID match: the same model on another USB port.
    [self readOutputModesForDeviceUID:(_modesUIDForNextSelection ?: uid)
                     bitPerfectOutput:&bitPerfectOutput exclusiveOutput:&exclusiveOutput];
    BOOL previousBitPerfect = _bitPerfectWanted;
    _bitPerfectWanted = bitPerfectOutput;
    BOOL previousExclusive = _exclusiveOutputWanted;
    _exclusiveOutputWanted = exclusiveOutput;
    BOOL didBind = [self setOutputDeviceOnQueue:outputDeviceID];
    if (self.currentlyRequestedAudioDeviceId != outputDeviceID) {
        _bitPerfectWanted = previousBitPerfect;
        _exclusiveOutputWanted = previousExclusive;
        // TRAP: a failed rebuild may already have rewired or prepared the
        // destination, so a Stopped player leaves it; a player still holding
        // its track keeps it.
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

    // Nothing is audible across a rebind: the output stops, which kills every
    // retiring voice, and the current voice keeps its ring and gain for the
    // restart. Drop the display/FFT activity now, before a potentially slow
    // HAL rebind, rather than waiting for the final restored state.
    [self stopOutputOnQueue];

    // Restore and release only after the output stopped. Restoring a hogged
    // device's format under a running output can strand its next start in
    // CoreAudio (error 35). A same-device recovery keeps the format and hog
    // while their settings still want them.
    if (!_bitPerfectWanted || (_preparedDeviceID != kAudioObjectUnknown && _preparedDeviceID != deviceID)) {
        [self leaveOutputDeviceOnQueue];
    }
    else if (!_exclusiveOutputWanted) {
        [self releaseExclusiveOutputOnQueue];
    }

    if (deviceID != kAudioObjectUnknown && ![self setOutputUnitDevice:deviceID]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not switch audio output device", nil)];
        return NO;
    }
    [self followOutputDeviceRateOnQueue];
    [self reconcileFXOnQueue];

    if (shouldRestore) {
        // Reuse the open handle: reopening the URL here, synchronously and
        // with no deadline, would wedge the queue on an evicted cloud
        // placeholder or a hung mount. processingFormat is fixed at open, so a
        // new voice on the existing file is safe.
        AudioFileHandle *file = _file; // safe: _file is only written on _queue, and we are on it
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
    
        // Restoring means Playing or Paused (getPlaybackIntent:), so the
        // helper's Paused-only idle stop covers every non-playing case here.
        if (![self resumeOutputAfterEditOnQueue:wasPlaying reason:@"device rebind"]) {
            return NO;
        }
        [self maybeArmSuccessorOnQueue]; // re-queue the successor behind the restored voice
    }

    return YES;
}

- (BOOL)setOutputDeviceOnQueue:(NSInteger)outputDeviceID {
    if (_terminating) return NO;

    LogDebug(@"setOutputDevice: %@", @(outputDeviceID));

    AudioDeviceID newDeviceID = kAudioObjectUnknown;
    NSArray<AudioDevice *> *devices = nil;
    if (outputDeviceID >= 0) {
        newDeviceID = (AudioDeviceID)outputDeviceID;
    }
    else {
        // TRAP: the default comes from the manager's snapshot, which it
        // refreshes before either observer fires, never from the HAL: a read
        // here waits behind coreaudiod and holds every transport command.
        devices = AudioDeviceManager.sharedInstance.cachedOutputDevices;
        for (AudioDevice *device in devices) {
            if (device.isSystemDefault) {
                newDeviceID = (AudioDeviceID)device.deviceId;
                break;
            }
        }
    }

    if (newDeviceID == kAudioObjectUnknown && devices.count > 0) {
        // Devices exist but none is the default: macOS names none for a moment
        // while it moves the default. The bound unit keeps
        // playing, and the default's notification or one retry binds it.
        LogWarn(@"AudioPlayer: no system default output device among %lu devices yet", (unsigned long)devices.count);
        self.currentlyRequestedAudioDeviceId = -1;
        [self notifyRequestedOutputDeviceOnQueue];
        [self scheduleSystemOutputBindRetryOnQueue];
        return NO;
    }
    if (newDeviceID == kAudioObjectUnknown && !devices) {
        // No snapshot yet says nothing about whether hardware exists. Do not
        // tear down or park a graph on that unknown verdict.
        LogWarn(@"AudioPlayer: no device snapshot to find the system default output device in");
        self.currentlyRequestedAudioDeviceId = -1;
        [self notifyRequestedOutputDeviceOnQueue];
        [self scheduleSystemOutputBindRetryOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not read the system output device", nil)];
        return NO;
    }

    if (newDeviceID == kAudioObjectUnknown) {
        // A published snapshot with no output device at all. Only the -1 path
        // can land here — every concrete id is a real enumerated device — so
        // following System Output remains the honest committed choice while
        // nothing exists to bind.
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
// mutation, not only when the id moved. The delegate persists it and drives
// the menu checkmark, idempotently. Skipping the unchanged case would leave a
// disagreement between Settings and the binding — a failed bind, a launch
// preference resolved to the id already requested — with no call left to
// resynchronize them. The delegate hop is to main.
- (void)notifyRequestedOutputDeviceOnQueue {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    // Here, not in the rebuild: the report's eligibility follows the
    // committed id.
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
        id<AudioPlayerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(audioPlayer:didChangeOutputDevice:involuntaryFallbackUID:involuntaryFallbackName:carriedModesFromUID:)]) {
            [delegate audioPlayer:self didChangeOutputDevice:requested involuntaryFallbackUID:fallbackUID
                involuntaryFallbackName:fallbackName carriedModesFromUID:modesUID];
        }
        if (modesUID.length && destinationUID.length) {
            os_unfair_lock_lock(&self->_stateLock);
            if ([self->_unpersistedOutputModeSources[destinationUID] isEqual:modesUID]) {
                [self->_unpersistedOutputModeSources removeObjectForKey:destinationUID];
            }
            os_unfair_lock_unlock(&self->_stateLock);
        }
    });
}

@end

#pragma mark - Output devices (public API, declared in AudioPlayer+Devices.h)

@implementation AudioPlayer (Devices)

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
            // Commit after the synchronous rebuild accepts the selection.
            // The queued HAL bind can still fail later.
            self->_pendingSavedDeviceUID = nil;
            self->_pendingSavedDeviceName = nil;
            self->_pendingSavedDeviceModelUID = nil;
        }
        run_on_main_thread({ completion(); });
    });
}

- (void)prepareForTermination {
    [self runSyncOnQueue:^{
        // Stop owns the open and prefetch cancellation; _terminating closes
        // admission first so nothing queued behind can restart the output.
        self->_terminating = YES;
        [self stopOnQueue];
        [self stopOutputOnQueue];
        [self leaveOutputDeviceOnQueue];
        LogInfo(@"AudioPlayer: termination cleanup complete");
    }];
}

#pragma mark - Diagnostics

- (NSDictionary<NSString *, id> *)outputDeviceDiagnosticSnapshot {
    __block NSDictionary *snapshot;
    [self runSyncOnQueue:^{
        snapshot = @{
            @"boundOutputDeviceId": @([self activeOutputDeviceID]),
            @"requestedOutputDeviceId": @(self.currentlyRequestedAudioDeviceId),
            @"pendingDeviceUID": self->_pendingSavedDeviceUID ?: @"",
            @"pendingDeviceModelUID": self->_pendingSavedDeviceModelUID ?: @"",
            @"pendingDeviceName": self->_pendingSavedDeviceName ?: @"",
            @"savedDeviceLookupInFlight": @(self->_pendingSavedDeviceLookupInFlight),
            @"bitPerfectWanted": @(self->_bitPerfectWanted),
            @"exclusiveOutputWanted": @(self->_exclusiveOutputWanted),
            @"hoggedDeviceId": @(self->_hoggedDeviceID == kAudioObjectUnknown ? -1 : (NSInteger)self->_hoggedDeviceID),
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
