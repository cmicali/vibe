//
//  AudioPlayer+Graph.m
//  Vibe
//

#import "AudioPlayer+Graph.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#if TARGET_OS_OSX
#import "CoreAudioUtil.h"
#endif
#if DEBUG
#import "VibeManualRenderPump.h"
#endif

// Give the next track time to open before releasing the idle engine.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 6.0;
// The hardware drain: the bus reports its events within this of their render.
static const uint64_t kDrainIntervalNanos = 10 * NSEC_PER_MSEC;
// An engine start holding the player queue longer than this is worth a line
// even in stable builds.
static const NSTimeInterval kSlowEngineStartLogThresholdSeconds = 0.25;
#if TARGET_OS_OSX
// The largest pull the engine's realtime block accepts; the unit slices a
// larger IO cycle into pulls of this.
static const AVAudioFrameCount kVibeOutputUnitMaxFrames = 4096;
#endif

@implementation AudioPlayer (Graph)

#pragma mark - The engine and the master bus

- (void)createEngineAndMasterBusOnQueue {
    _engine = [[AVAudioEngine alloc] init];
    BOOL masterBusWired = NO;
#if DEBUG
    // --no-audio-hw, for testing: put the engine in manual rendering mode so
    // it never opens a CoreAudio output device. Starting the hardware IO —
    // even with the mixer muted — counts as the Mac playing audio, which is
    // enough for macOS to yank auto-switching AirPods over from another device
    // mid-test. Must be enabled while the engine is stopped and before the
    // graph is wired.
    VibeManualRenderPump *pump = _manualPump;
    BOOL noAudioHW = pump != nil || [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    BOOL manualRendering = NO;
    if (noAudioHW) {
        NSError *manualError = nil;
        AVAudioFormat *renderFormat = pump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
        manualRendering = [_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                                      format:renderFormat
                                           maximumFrameCount:kVibeManualPumpMaxFrames
                                                       error:&manualError];
        if (!manualRendering) {
            if (pump) [NSException raise:NSInternalInconsistencyException format:@"Manual rendering required: %@", manualError];
            // Pair --no-audio-hw with --silent, as launch.sh does, and
            // playback at least stays inaudible.
            LogError(@"AudioPlayer: --no-audio-hw manual rendering unavailable (%@)", manualError);
        }
    }
    if (manualRendering) {
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:_engine.manualRenderingFormat];
        if (!pump) {
            pump = [[VibeManualRenderPump alloc] initWithFormat:_engine.manualRenderingFormat automatic:YES];
            _manualPump = pump;
        }
        // The pump stands in for the IO thread: the frame-driven mode decodes
        // inline before each slice, and both modes drain after it.
        __weak AudioPlayer *weakSelf = self;
        pump.beforeRender = pump.automatic ? nil : ^{
            AudioPlayer *strongSelf = weakSelf;
            [strongSelf->_voiceBus fillInline];
        };
        pump.afterRender = ^{ [weakSelf drainVoiceBusOnQueue]; };
        [pump attachToEngine:_engine queue:_queue];
        LogInfo(@"AudioPlayer: --no-audio-hw, manual rendering, no output device");
    }
#endif
#if TARGET_OS_OSX
#if DEBUG
    BOOL hosted = !manualRendering;
#else
    BOOL hosted = YES;
#endif
    if (hosted) {
        // Vibe hosts the output: the engine renders in realtime manual mode
        // and the unit's callback pulls it into the device. It begins on the
        // system default at that device's rate; the saved device binds
        // asynchronously through the checked device-switch path.
        _outputUnit = [[AudioOutputUnit alloc] init];
        if (!_outputUnit) {
            LogError(@"AudioPlayer: no HAL output unit; falling back to the engine's own output node");
        }
        AudioDeviceID deviceID = kAudioObjectUnknown;
        Float64 rate = 0;
        if ([CoreAudioUtil readSystemDefaultOutputDeviceID:&deviceID] && deviceID != kAudioObjectUnknown) {
            OSStatus status = [_outputUnit bindToDevice:deviceID];
            if (status != noErr) {
                LogError(@"AudioPlayer: could not bind the output unit to device %u (OSStatus %d)", deviceID, (int)status);
            }
            [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID];
        }
        masterBusWired = [self applyOutputRateOnQueue:rate > 0 ? rate : 44100];
    }
#endif
    if (!masterBusWired) {
        [self installMasterBusOnQueue];
    }
#if DEBUG
    // --silent, for testing: zero the main mixer so that playback runs
    // normally but nothing audible reaches the output device, which still gets
    // opened and driven. It sits downstream of every voice's gain and upstream
    // of the FX returns, so wet tails are silenced too. It must run after the
    // master bus is wired, because a mixer volume written before the mixer is
    // attached and wired is silently dropped. See AudioFX.m.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]) {
        _engine.mainMixerNode.outputVolume = 0;
        LogInfo(@"AudioPlayer: --silent, output muted");
    }
#endif
}

// The explicit connect stands in for the implicit one AVAudioEngine makes on
// mainMixerNode access, so the wiring is the same deterministic step in every
// configuration: engine init, the iOS rebuild, and the macOS device rebind
// whenever the standing route disagrees with the flags.
- (void)installMasterBusOnQueue {
    [self reconnectMasterBusOnQueueWithFormat:[_engine.mainMixerNode outputFormatForBus:0]];
}

- (void)reconnectMasterBusOnQueueWithFormat:(AVAudioFormat *)format {
    [_levelTap remove];
    _levelTap = nil;
    // Apple's default SRC leaves measurable ultrasonic aliases when reducing
    // the output rate. The render suite holds their RMS below -90 dBFS.
    _engine.mainMixerNode.AUAudioUnit.renderQuality = kRenderQuality_Max;
    BOOL enableFX = _fxEnabled;
#if TARGET_OS_OSX
    enableFX &= !_bitPerfectWanted;
#endif
    [self.fx setConnected:enableFX inEngine:_engine format:format];
    if (!self.fx.masterBusOutputNode) {
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:format];
    }
    // TRAP: every master-bus rewire must reconcile the tap on the new output path.
    [self applyLevelTapOnQueue];
}

- (void)applyLevelTapOnQueue {
    BOOL wanted = _levelsWanted || self.signalProbeWanted;
    if (wanted && _engine && !_levelTap && _levelPublisher) {
        // Whatever feeds the output, which is the only place the bars can
        // follow what is actually heard: the FX segment's sum when there is
        // one, the mixer itself when there is not, since the returns re-enter
        // downstream of it.
        AVAudioNode *tapNode = self.fx.masterBusOutputNode ?: _engine.mainMixerNode;
        _levelTap = [[AudioLevelTap alloc] initWithNode:tapNode
                                              publisher:_levelPublisher
                                       normalizationMode:_levelNormalizationMode];
        if (_state == VibePlayerStatePlaying && _voice) {
            [self armSignalProbeOnQueue:@"tap installed during playback"];
        }
    }
    else if (!wanted && _levelTap) {
        [_levelTap remove];
        _levelTap = nil;
    }
}

#if TARGET_OS_OSX
// TRAP: never disableManualRenderingMode — it opens the default output
// device. The rate changes by enabling manual rendering again at the new
// format, which keeps every node and connection (measured: rtrender.swift).
- (BOOL)applyOutputRateOnQueue:(double)rate {
    if (!_outputUnit) {
        return NO;
    }
    if (_engine.isInManualRenderingMode && _engine.manualRenderingFormat.sampleRate == rate
            && _outputUnit.format.sampleRate == rate) {
        return YES;
    }
    [self stopEngineOnQueue];
    [_levelTap remove];
    _levelTap = nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    NSError *error = nil;
    if (![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:format
                          maximumFrameCount:kVibeOutputUnitMaxFrames error:&error]) {
        LogError(@"AudioPlayer: realtime manual rendering at %.0f Hz refused (%@)", rate, error);
        return NO;
    }
    if (![_outputUnit configureFormat:format maximumFrameCount:kVibeOutputUnitMaxFrames
                          renderBlock:_engine.manualRenderingBlock error:&error]) {
        LogError(@"AudioPlayer: output unit refused %.0f Hz (%@)", rate, error);
        return NO;
    }
    // The master bus is wired at the new format directly, never read back
    // from the mixer, whose output still carries the old rate until the
    // wiring sets it; the FX segment rewires itself whole across a rate.
    [self reconnectMasterBusOnQueueWithFormat:format];
    LogInfo(@"AudioPlayer: output unit pulls at %.0f Hz from device %u", rate, _outputUnit.deviceID);
    return YES;
}
#endif

#pragma mark - The source segment

- (AVAudioFormat *)decodeFormatOnQueueForFile:(AVAudioFile *)file {
    AVAudioFormat *format = file.processingFormat;
#if TARGET_OS_OSX
    if ([self decodesAsInteger16OnQueueForFile:file]) {
        AVAudioFormat *integer = format.channelLayout
                ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:format.sampleRate
                                                  interleaved:YES channelLayout:format.channelLayout]
                : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:format.sampleRate
                                                     channels:format.channelCount interleaved:YES];
        if (integer) {
            return integer;
        }
    }
#endif
    return format;
}

- (BOOL)ensureSourceSegmentOnQueueForFile:(AVAudioFile *)file rebuilt:(BOOL *)rebuilt {
    if (rebuilt) {
        *rebuilt = NO;
    }
    // Bit-perfect output delivers each file at its own format, with no
    // varispeed; ordinary playback has one bus format for the engine's life,
    // the mixer's own, so the bus converts every file once and the mixer
    // converts nothing.
    BOOL bitPerfect = [self bitPerfectOnQueue];
    AVAudioFormat *wanted = bitPerfect ? file.processingFormat : [_engine.mainMixerNode outputFormatForBus:0];
    AVAudioFormat *busFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:wanted.sampleRate
                                                                              channels:wanted.channelCount];
    if (_voiceBus && _voiceBus.format.sampleRate == busFormat.sampleRate
            && _voiceBus.format.channelCount == busFormat.channelCount && (_varispeed == nil) == bitPerfect) {
        return YES;
    }
    // Every voice dies with the old segment; the callers made sure none was
    // audible. The engine must be stopped to rewire. The bus pointer is
    // written under the lock because the position getter reads it off it.
    [self stopEngineOnQueue];
    if (_voiceBus) {
        [_engine detachNode:_voiceBus.sourceNode];
        os_unfair_lock_lock(&_stateLock);
        _voiceBus = nil;
        os_unfair_lock_unlock(&_stateLock);
        [_retiringVoices removeAllObjects];
        [self unpublishVoiceOnQueue];
    }
    if (_varispeed) {
        [_engine detachNode:_varispeed];
        _varispeed = nil;
    }
#if DEBUG
    BOOL inlineDecoding = _manualPump != nil && ![(VibeManualRenderPump *)_manualPump automatic];
#else
    BOOL inlineDecoding = NO;
#endif
    AudioVoiceBus *bus = [[AudioVoiceBus alloc] initWithFormat:busFormat queue:_queue inlineDecoding:inlineDecoding];
    if (!bus) {
        LogError(@"AudioPlayer: no voice bus for %@", busFormat);
        return NO;
    }
    __weak AudioPlayer *weakSelf = self;
    bus.voiceWentLive = ^{ [weakSelf drainVoiceBusOnQueue]; };
    [_engine attachNode:bus.sourceNode];
    if (!bitPerfect) {
        _varispeed = [[AVAudioUnitVarispeed alloc] init];
        [_engine attachNode:_varispeed];
    }
    @try {
        if (_varispeed) {
            [_engine connect:bus.sourceNode to:_varispeed format:busFormat];
            [_engine connect:_varispeed to:_engine.mainMixerNode format:busFormat];
        }
        else {
            [_engine connect:bus.sourceNode to:_engine.mainMixerNode format:busFormat];
        }
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: engine connect failed for %@: %@", busFormat, exception);
        [_engine detachNode:bus.sourceNode];
        if (_varispeed) {
            [_engine detachNode:_varispeed];
            _varispeed = nil;
        }
        return NO;
    }
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = bus;
    _busSampleRate = busFormat.sampleRate;
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    [self applyPitchOnQueue:pitch];
    if (rebuilt) {
        *rebuilt = YES;
    }
    return YES;
}

// The one mapping from the published pitch to the varispeed: a ratio, and
// bypass at zero, because even a ratio of 1.0 is not a pass-through.
- (void)applyPitchOnQueue:(float)pitch {
    _varispeed.rate = 1.0f + pitch / 100.0f;
    _varispeed.bypass = pitch == 0;
}

#pragma mark - Starting and stopping

- (BOOL)startEngineOnQueue:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    if (_terminating) {
        return NO;
    }
    _engineIdleStopGeneration++; // playback is starting: cancel any pending idle stop
    if (!_engine.isRunning) {
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
        [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
            [self acquireExclusiveOutputOnQueue];
            return YES; // ownership confirmation is logged by the nested hog phase
        }];
#endif
        __block NSError *startError = nil;
        uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL started = [self performDiagnosticPhase:@"engine start" device:-1 operation:^BOOL{
            return [self->_engine startAndReturnError:&startError];
        }];
        NSTimeInterval seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt) / NSEC_PER_SEC;
        BOOL slow = seconds > kSlowEngineStartLogThresholdSeconds;
        LogTiming(slow, @"AudioPlayer: %@engine start %.3fs (the player queue was blocked for this long)",
                  slow ? @"slow " : @"", seconds);
        if (!started) {
            if (outError) {
                *outError = startError;
            }
            return NO;
        }
    }
    // A tap request made against a not-yet-runnable graph can observe a
    // temporarily unusable output format and return nil; an engine start is
    // the next lifecycle edge to retry it on.
    [self applyLevelTapOnQueue];
#if TARGET_OS_OSX
    // The unit starts last, so the engine is running whenever its gate is open.
    if (_outputUnit && !_outputUnit.running) {
        __block NSError *unitError = nil;
        BOOL pulling = [self performDiagnosticPhase:@"output unit start" device:(NSInteger)_outputUnit.deviceID operation:^BOOL{
            return [self->_outputUnit startWithError:&unitError];
        }];
        if (!pulling) {
            [_engine stop];
            if (outError) {
                *outError = unitError;
            }
            return NO;
        }
    }
#endif
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
    return YES;
}

- (void)stopEngineOnQueue {
#if TARGET_OS_OSX
    [_outputUnit stop]; // gate closed and no cycle in flight before the engine stops
#endif
    [_engine stop];
    for (NSNumber *voice in _retiringVoices) {
        [_voiceBus killVoice:voice.unsignedLongLongValue];
    }
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
}

- (void)scheduleEngineIdleStopOnQueue {
    if (_terminating) {
        return;
    }
    uint64_t generation = ++_engineIdleStopGeneration;
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:kEngineIdleStopDelaySeconds block:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_engineIdleStopGeneration) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_stateLock);
        VibePlayerState state = strongSelf->_state;
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        // Only a still-idle player stops the engine. Loading counts as busy,
        // because the in-flight open's settlement wants a warm engine. A
        // paused voice keeps its state; resume restarts the engine.
        if (state != VibePlayerStateStopped && state != VibePlayerStatePaused) {
            return;
        }
        [strongSelf stopEngineOnQueue];
#if TARGET_OS_OSX && VIBE_ENABLE_EXCLUSIVE_OUTPUT
        [strongSelf releaseExclusiveOutputOnQueue];
#endif
    }];
}

#pragma mark - The drain

- (void)drainVoiceBusOnQueue {
    AudioVoiceBus *bus = _voiceBus;
    if (!bus) {
        return;
    }
    [bus drainWithEngineRunning:_engine.isRunning handler:^(VibeVoiceID voice, VibeVoiceEvent event) {
        BOOL current = voice == self->_voice;
        [self noteBusEvent:event voice:voice current:current];
        switch (event) {
            case VibeVoiceEventLive:
                break;
            case VibeVoiceEventBoundary:
                if (current) {
                    [self promoteSuccessorOnQueue];
                }
                break;
            case VibeVoiceEventEnded:
                if (current) {
                    [self currentVoiceEndedOnQueue:voice];
                }
                else if ([self->_retiringVoices containsObject:@(voice)]) {
                    [self->_retiringVoices removeObject:@(voice)];
                    if (self->_retiringVoices.count == 0) {
                        [self noteRetiringAudioSilentOnQueue];
                    }
                    [self refreshOutputAudioActiveOnQueue];
                }
                break;
        }
    }];
    [self updateDrainTimerOnQueue];
}

// A current voice ends of its own accord only at end of stream; a voice cut
// for a reason the transport chose was unpublished first. The exception is
// a decode that could not start, which the bus reports as a retire with
// nothing consumed.
- (void)currentVoiceEndedOnQueue:(VibeVoiceID)voice {
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:voice];
    if (snapshot.ended == VibeVoiceEndRetired && snapshot.consumed == 0) {
        AudioTrack *track = self.currentTrack;
        uint64_t submittedPlay = _activeSubmittedPlayIdentifier;
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not decode %@", track.url.lastPathComponent], nil, track.url)
               forSubmittedPlay:submittedPlay];
        return;
    }
    [self finishPlaybackOnQueue];
}

- (void)updateDrainTimerOnQueue {
#if DEBUG
    if (_manualPump) {
        return; // the pump drains after every slice
    }
#endif
    BOOL wanted = _engine.isRunning && _voiceBus.occupiedSlotCount > 0;
    if (wanted == (_drainTimer != nil)) {
        return;
    }
    if (!wanted) {
        dispatch_source_cancel(_drainTimer);
        _drainTimer = nil;
        return;
    }
    _drainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_drainTimer, dispatch_time(DISPATCH_TIME_NOW, kDrainIntervalNanos),
                              kDrainIntervalNanos, kDrainIntervalNanos / 4);
    __weak AudioPlayer *weakSelf = self;
    dispatch_source_set_event_handler(_drainTimer, ^{ [weakSelf drainVoiceBusOnQueue]; });
    dispatch_resume(_drainTimer);
}

#pragma mark - Rebuilding

// The caller may hold a defunct engine whose graph must not be touched, as
// after an iOS media-services reset. The bus goes with it: its voices' files
// died with the media server, and the render block's memory outlives the bus
// on its own. The park and the pending open go too — the file handles they
// would produce are dead, and a download without a consumer is waste.
- (void)dropEngineBoundStateOnQueue {
    if (_drainTimer) {
        dispatch_source_cancel(_drainTimer);
        _drainTimer = nil;
    }
    [_retiringVoices removeAllObjects];
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = nil;
    _voice = 0;
    os_unfair_lock_unlock(&_stateLock);
    _varispeed = nil;
    // Abandoned rather than removed: removeTapOnBus: would message a node
    // belonging to the engine this method exists to stop touching.
    [_levelTap abandon];
    _levelTap = nil;
    _engine = nil;
    [self refreshOutputAudioActiveOnQueue];
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    [_pendingRequest invalidate];
    [self clearSuccessorOnQueue];
}

@end
