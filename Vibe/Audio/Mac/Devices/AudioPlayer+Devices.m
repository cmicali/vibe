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

// Format changes and restoration wait, with the output stopped, for the
// device to confirm the write before the graph follows its rate.
static const NSTimeInterval kFormatSwitchDeadlineSeconds = 1.5;
static const useconds_t kFormatSwitchPollMicroseconds = 5000;

// A rebind slower than this holds the player queue long enough to feel like a
// freeze.
static const NSTimeInterval kSlowDeviceRebindLogThresholdSeconds = 0.25;

// The longest the player queue waits on one bounded HAL read.
static const NSTimeInterval kDeviceReadWaitSeconds = 0.5;

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
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        device[@"exclusive"] = @(_hoggedDeviceID == deviceID);
#endif
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
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
        [self acquireExclusiveOutputOnQueue];
        return YES;
    }];
#endif
    [_outputUnit start]; // a refusal arrives later, at outputUnitFailedOnQueue:
    return YES;
}

- (void)releaseIdleOutputUnitOnQueue {
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    [self releaseExclusiveOutputOnQueue];
#endif
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
// kAudioObjectUnknown only before a first bind that found no device. Without
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
    uint64_t reboundAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL rebound = [self rebindOutputOnQueueToDevice:deviceID];
    NSTimeInterval seconds =
            (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - reboundAt) / NSEC_PER_SEC;
    BOOL slowRebind = seconds > kSlowDeviceRebindLogThresholdSeconds;
    LogTiming(slowRebind, @"AudioPlayer: %@device rebind to %u took %.3fs (%@)",
            slowRebind ? @"slow " : @"", deviceID, seconds, rebound ? @"bound" : @"FAILED");
    _rebindDeviceID = kAudioObjectUnknown;
    if (!rebound) {
        // Names who asked for a bind the HAL refused: a rebind onto a
        // vanishing device fails with -10851 and unloads the track. Release
        // builds log addresses, which symbolicate against the archived binary.
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
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    else if (!_exclusiveOutputWanted) {
        [self releaseExclusiveOutputOnQueue];
    }
#endif

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
    
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startOutputOnQueue:&startError]) {
                // No output to restart on. Park Paused at the same position,
                // so the next resume restarts the output, and say why.
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

    return YES;
}

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
    return (device && VibeBitPerfectDeviceEligible(device.transportType, _allowBitPerfectOnAnyDevice)) ? device : nil;
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
- (BOOL)resolveOutputFormatOnQueueForFile:(AudioFileHandle *)file
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

- (BOOL)outputNeedsSwitchOnQueueForFile:(AudioFileHandle *)file {
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
    // TRAP: the stop this write follows is only queued on the unit; a hogged
    // device's format written under a running output strands its next start
    // with error 35. Wait for it.
    [_outputUnit waitUntilIdle];
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

- (void)prepareOutputOnQueueForFile:(AudioFileHandle *)file {
    [self performDiagnosticPhase:@"output preparation" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
        [self prepareOutputFormatOnQueueForFile:file];
        return YES; // confirmation failures are reported by the nested format phase
    }];
}

- (void)prepareOutputFormatOnQueueForFile:(AudioFileHandle *)file {
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
        // loses at most a declick.
        [self stopOutputOnQueue];
    }
    if (formatDiffers) {
        // Restore is one slot: another device's outstanding restore is tried
        // first, and while it keeps failing this device keeps its format.
        BOOL owedElsewhere = _changedFormatDeviceID != kAudioObjectUnknown && _changedFormatDeviceID != deviceID;
        if (owedElsewhere) {
            [self restoreOutputFormatOnQueue]; // the output was stopped above
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
// The output is stopped at both ownership edges.
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
    // Taking the system default moves the default elsewhere; the hosted unit
    // stays bound. A successful write followed by a failed read-back may still
    // own the device, so the obligation is recorded BEFORE the take.
    if (_hoggedDeviceID != deviceID) {
        [_outputUnit waitUntilIdle]; // an ownership edge: after the queued stop, as the format write
    }
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
    [_outputUnit waitUntilIdle];
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
    // The third device obligation, retired like the other two: a vanished
    // device never accepts the removal, and a _preparedDeviceID left naming it
    // reads as "a device is prepared" to setOutputDeviceOnQueue:, so every
    // later bind would rebuild the graph.
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

// The output must be stopped. Retry once, then keep the obligation for the
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
// device, the hog, the current file, the prepared device's physical format
// read live and its volume, balance and mute (cached while its listener
// stands), the device's reads bounded — and publishes the copy the shell reads, announcing it when it
// differs. Held while a device switch is rebuilding. It gates itself: off,
// once the zeroed Off report is out, a call is two ivar reads.
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
        AudioFileHandle *file = _file; // queue-confined writer; the promoted splice file included
        UInt32 channels = file.fileFormat.channelCount;
        // No file (Loading) asks for no channels; the last track's reading covers it.
        controlsCached = _outputLevelListener && _outputControlsDeviceID == _preparedDeviceID
                && _outputControlsStreamID == _preparedStreamID
                && (_outputControlsChannels == channels || channels == 0);
        // Every device read in one bounded read: this rides every state
        // publication, and a hung device must not hold the queue for each.
        AudioDeviceID prepared = _preparedDeviceID;
        AudioStreamID stream = _preparedStreamID;
        NSArray<NSNumber *> *channelMap = _outputUnit.channelMap;
        BOOL readControls = !controlsCached;
        BOOL readOwner = NO;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        readOwner = _hoggedDeviceID == prepared;
#endif
        __block AudioStreamBasicDescription devicePhysical = {0};
        __block BOOL formatRead = NO, controlsRead = NO, ownerRead = NO, mapPreserves = NO, deviceMuted = NO;
        __block Float32 deviceVolume = 1, deviceBalance = 0.5f;
        __block pid_t owner = -1;
        BOOL answered = [CoreAudioUtil performBoundedRead:^{
            formatRead = [CoreAudioUtil readPhysicalFormat:&devicePhysical forStream:stream];
            if (readOwner) ownerRead = [CoreAudioUtil readHogOwner:&owner forDeviceID:prepared];
            if (readControls) {
                controlsRead = [CoreAudioUtil readOutputVolume:&deviceVolume balance:&deviceBalance mute:&deviceMuted
                                                      channels:channels inStream:stream forDeviceID:prepared];
            }
            mapPreserves = channels > 0 && [CoreAudioUtil channelMap:channelMap preservesChannels:channels inStream:stream
                                                physicalChannelCount:devicePhysical.mChannelsPerFrame];
        } within:kDeviceReadWaitSeconds late:nil];
        // A read that timed out is still writing its results: none is looked at.
        BOOL readFormat = answered && formatRead;
        AudioStreamBasicDescription physical = readFormat ? devicePhysical : (AudioStreamBasicDescription){0};
        AVAudioFormat *mixerFormat = [self masterBusFormatOnQueue];
        AVAudioFormat *unitFormat = _outputUnit.format;
        report.sampleRate = physical.mSampleRate;
        report.bitsPerChannel = physical.mBitsPerChannel;
        report.isFloat = VibePhysicalFormatIsFloat(physical);
        // Named rather than folded into one flag: "switch failed" alone does
        // not say which condition failed, and the debug info log is read for it.
        AudioDeviceID bound = [self activeOutputDeviceID];
        unconfirmed = !answered ? @"the device did not answer in time"
                : !readFormat ? @"the device's format could not be read"
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
        report.exclusive = readOwner && answered && ownerRead && owner == getpid();
#endif
        if (readControls) {
            BOOL read = answered && controlsRead;
            _outputControlsVolume = read ? deviceVolume : 1;
            _outputControlsBalance = read ? deviceBalance : 0.5f;
            _outputControlsMuted = read && deviceMuted;
            // A failed read is never kept, so the next publication tries again.
            _outputControlsDeviceID = read ? _preparedDeviceID : kAudioObjectUnknown;
            _outputControlsStreamID = _preparedStreamID;
            _outputControlsChannels = channels;
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
            // Keep the bus one-to-one; wider hardware is transparent only
            // when the AU's actual map preserves the prepared stream's pair.
            report.channelsMatch = channels > 0
                    && file.processingFormat.channelCount == channels
                    && mixerFormat.channelCount == channels
                    && unitFormat.channelCount == channels
                    && answered && mapPreserves;
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

- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput enableFX:(BOOL)enableFX allowAnyDevice:(BOOL)allowAnyDevice {
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
        changed |= desiredBitPerfect && self->_allowBitPerfectOnAnyDevice != allowAnyDevice;
        self->_allowBitPerfectOnAnyDevice = allowAnyDevice;
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
        // admission first so nothing queued behind can restart the output.
        self->_terminating = YES;
        [self stopOnQueue];
        [self stopOutputOnQueue];
        [self leaveOutputDeviceOnQueue];
        LogInfo(@"AudioPlayer: termination cleanup complete");
    }];
}

@end
