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
#include <stdatomic.h>
#include <unistd.h>

// Give the next track time to open before releasing the idle output.
static const NSTimeInterval kOutputIdleStopDelaySeconds = 6.0;
// The hardware drain: the bus reports its events within this of their render.
static const uint64_t kDrainIntervalNanos = 10 * NSEC_PER_MSEC;
// An output start holding the player queue longer than this is worth a line
// even in stable builds.
static const NSTimeInterval kSlowOutputStartLogThresholdSeconds = 0.25;
// A retire waits this long, at most, for a render already inside the bus.
static const useconds_t kRetireSpinMicroseconds = 200;
static const int kRetireSpinLimit = 500; // 100 ms

#pragma mark - The master bus

// The most channels the meter is handed; wider outputs meter their first ones.
enum { kVibeOutputMaxChannelsForMeter = 8 };

// What the audio thread reads. Writers: the queue (the pointers, with the
// output stopped or through the flag the render checks first; the gate and
// the flags), the render (the counters and inRender).
struct VibeMasterBus {
    _Atomic int32_t gate;            // 1 while the output may render
    _Atomic int32_t inRender;        // 1 while the render is inside the pipeline
    _Atomic uint64_t frames;         // the output timeline: frames rendered
    _Atomic uint32_t pendingFrames;  // the block in flight
    _Atomic int32_t meterWanted;
    _Atomic int32_t silent;          // --silent: the meter sees the signal, the device zeros
    _Atomic uint64_t varispeedRenders;
    _Atomic(VibeVoiceMix *) mix;     // the bus; NULL until the first settlement
    _Atomic(AudioUnit) varispeed;    // ordinary playback on macOS; NULL otherwise
    _Atomic(VibeFXChain *) chain;    // the FX segment, which decides for itself whether it is connected
    _Atomic(VibeLevelMeter *) meter; // the equalizer's, while wanted
    double sampleRate;
    uint32_t channels;
};

// The two calls the compiler cannot check: the varispeed's render, which
// AudioToolbox documents as the render thread's own entry point and
// attributes with nothing, and the meter's, which wraps the analyzer's FFT.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
#endif
static inline OSStatus VibeMasterBusRenderVarispeed(AudioUnit varispeed, const AudioTimeStamp *stamp, UInt32 frames,
                                                    AudioBufferList *data) CA_REALTIME_API {
    AudioUnitRenderActionFlags flags = 0;
    return AudioUnitRender(varispeed, &flags, stamp, 0, frames, data);
}

static inline void VibeMasterBusMeter(VibeLevelMeter *meter, float *const *channels, UInt32 channelCount, UInt32 frames,
                                      double sampleRate, const AudioTimeStamp *stamp) CA_REALTIME_API {
    VibeLevelMeterRender(meter, channels, channelCount, frames, sampleRate, stamp);
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

// Everything the audio thread does. Plain memory and atomics, no call that
// can block; the pragma makes the compiler hold that line.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wfunction-effects"
#endif
static inline void VibeMasterBusZero(AudioBufferList *data, UInt32 frames) CA_REALTIME_API {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset(data->mBuffers[b].mData, 0, frames * sizeof(float));
        }
    }
}

// The varispeed's input: the bus, for whatever count the unit asks.
static OSStatus VibeMasterBusVarispeedInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *stamp,
                                            UInt32 bus, UInt32 frames, AudioBufferList *data) CA_REALTIME_API {
    VibeMasterBus *master = refCon;
    VibeVoiceMix *mix = atomic_load_explicit(&master->mix, memory_order_relaxed);
    if (!mix || !data) {
        if (data) {
            VibeMasterBusZero(data, frames);
        }
        if (flags) {
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }
    BOOL silence = NO;
    OSStatus status = VibeVoiceBusRender(mix, &silence, stamp, frames, data);
    if (silence && flags) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return status;
}

static OSStatus VibeMasterBusRender(VibeMasterBus *master, const AudioTimeStamp *hostStamp, UInt32 frames,
                                    AudioBufferList *data) CA_REALTIME_API {
    atomic_store_explicit(&master->inRender, 1, memory_order_seq_cst);
    if (!atomic_load_explicit(&master->gate, memory_order_seq_cst) || !data || data->mNumberBuffers < master->channels
            || frames == 0 || frames > kVibeMasterBusMaxFrames) {
        if (data) {
            VibeMasterBusZero(data, frames);
        }
        atomic_store_explicit(&master->inRender, 0, memory_order_release);
        return noErr;
    }
    // The stamp every stage sees: sample time on the output timeline, host
    // time from the carrier's cycle when it has one.
    uint64_t rendered = atomic_load_explicit(&master->frames, memory_order_relaxed);
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = (Float64)rendered;
    stamp.mFlags = kAudioTimeStampSampleTimeValid;
    if (hostStamp && (hostStamp->mFlags & kAudioTimeStampHostTimeValid)) {
        stamp.mHostTime = hostStamp->mHostTime;
        stamp.mFlags |= kAudioTimeStampHostTimeValid;
    }
    atomic_store_explicit(&master->pendingFrames, frames, memory_order_release);
    OSStatus status = noErr;
    VibeVoiceMix *mix = atomic_load_explicit(&master->mix, memory_order_relaxed);
    AudioUnit varispeed = atomic_load_explicit(&master->varispeed, memory_order_relaxed);
    if (!mix) {
        VibeMasterBusZero(data, frames);
    }
    else if (varispeed) {
        atomic_fetch_add_explicit(&master->varispeedRenders, 1, memory_order_relaxed);
        status = VibeMasterBusRenderVarispeed(varispeed, &stamp, frames, data);
    }
    else {
        BOOL silence = NO;
        status = VibeVoiceBusRender(mix, &silence, &stamp, frames, data);
    }
    VibeFXChain *chain = atomic_load_explicit(&master->chain, memory_order_relaxed);
    if (chain) {
        VibeFXChainRender(chain, &stamp, frames, data);
    }
    VibeLevelMeter *meter = atomic_load_explicit(&master->meterWanted, memory_order_seq_cst)
            ? atomic_load_explicit(&master->meter, memory_order_relaxed) : NULL;
    if (meter) {
        float *channels[kVibeOutputMaxChannelsForMeter];
        UInt32 count = master->channels < kVibeOutputMaxChannelsForMeter ? master->channels : kVibeOutputMaxChannelsForMeter;
        for (UInt32 c = 0; c < count; c++) {
            channels[c] = data->mBuffers[c].mData;
        }
        VibeMasterBusMeter(meter, channels, count, frames, master->sampleRate, &stamp);
    }
    if (atomic_load_explicit(&master->silent, memory_order_relaxed)) {
        VibeMasterBusZero(data, frames);
    }
    atomic_store_explicit(&master->frames, rendered + frames, memory_order_release);
    atomic_store_explicit(&master->pendingFrames, 0, memory_order_release);
    atomic_store_explicit(&master->inRender, 0, memory_order_release);
    return status;
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

#if TARGET_OS_OSX
// The output unit's proc; the master bus is the refCon.
static OSStatus VibeMasterBusRenderProc(void *refCon, const AudioTimeStamp *timestamp, UInt32 frames,
                                        AudioBufferList *data) CA_REALTIME_API {
    return VibeMasterBusRender(refCon, timestamp, frames, data);
}
#endif

@implementation AudioPlayer (Graph)

#pragma mark - The carrier

- (void)createOutputOnQueue {
    if (!_masterBus) {
        _masterBus = calloc(1, sizeof(VibeMasterBus));
    }
    _retiredRenderState = _retiredRenderState ?: [NSMutableArray array];
#if DEBUG
    // --no-audio-hw, for testing: no device is opened at all, and the pump
    // stands in for the IO thread, calling the pipeline at real-time pace or,
    // frame-driven, when a test asks. Starting the hardware IO — even muted —
    // counts as the Mac playing audio, which is enough for macOS to yank
    // auto-switching AirPods over from another device mid-test.
    VibeManualRenderPump *pump = _manualPump;
    BOOL noAudioHW = pump != nil || [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    // --silent, for testing: the pipeline renders normally, the meter sees
    // the signal, and the buffers are zeroed on their way to the device,
    // which still gets opened and driven.
    atomic_store_explicit(&_masterBus->silent, [NSProcessInfo.processInfo.arguments containsObject:@"--silent"] ? 1 : 0,
                          memory_order_relaxed);
#elif TARGET_OS_OSX
    const BOOL noAudioHW = NO;
#endif
#if TARGET_OS_OSX
    if (!noAudioHW) {
        // Vibe hosts the output: the unit's callback pulls the pipeline into
        // the device. It begins on the system default at that device's rate;
        // the saved device binds asynchronously through the checked
        // device-switch path.
        _outputUnit = [[AudioOutputUnit alloc] init];
        if (!_outputUnit) {
            LogError(@"AudioPlayer: no HAL output unit; nothing will play");
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
        if (![self applyOutputRateOnQueue:rate > 0 ? rate : 44100]) {
            [self setMasterBusFormatOnQueue:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate > 0 ? rate : 44100 channels:2]];
        }
        return;
    }
#if DEBUG
    AVAudioFormat *format = pump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
    if (!pump) {
        pump = [[VibeManualRenderPump alloc] initWithFormat:format automatic:YES];
        _manualPump = pump;
    }
    // The pump is attached before the format lands: the format's FX reconcile
    // schedules its ramps through the pump, which needs its queue by then.
    // The gate is closed, so the paced pump renders silence until a start.
    VibeMasterBus *master = _masterBus; // the blocks capture the pointer, never self
    [self attachPumpOnQueue:pump render:^OSStatus(const AudioTimeStamp *timestamp, AVAudioPCMBuffer *chunk, AVAudioFrameCount count) {
        chunk.frameLength = count;
        return VibeMasterBusRender(master, timestamp, count, chunk.mutableAudioBufferList);
    } running:^BOOL{
        return atomic_load_explicit(&master->gate, memory_order_relaxed) != 0;
    }];
    [self setMasterBusFormatOnQueue:format];
    LogInfo(@"AudioPlayer: --no-audio-hw, no output device");
#endif
#else
    // iOS: the engine is the carrier and nothing else — one source node,
    // whose block is the pipeline, into its output node.
    _engine = [[AVAudioEngine alloc] init];
    AVAudioFormat *format = nil;
#if DEBUG
    if (noAudioHW) {
        NSError *manualError = nil;
        AVAudioFormat *renderFormat = pump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
        if ([_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:renderFormat
                             maximumFrameCount:kVibeManualPumpMaxFrames error:&manualError]) {
            format = _engine.manualRenderingFormat;
            if (!pump) {
                pump = [[VibeManualRenderPump alloc] initWithFormat:format automatic:YES];
                _manualPump = pump;
            }
            AVAudioEngine *engine = _engine;
            [self attachPumpOnQueue:pump render:^OSStatus(const AudioTimeStamp *timestamp, AVAudioPCMBuffer *chunk, AVAudioFrameCount count) {
                // A graph mutation can temporarily prevent rendering. Retry only
                // a zero-frame result; never discard or duplicate a partial block.
                NSError *error = nil;
                AVAudioEngineManualRenderingStatus status;
                NSUInteger attempts = 0;
                do {
                    status = [engine renderOffline:count toBuffer:chunk error:&error];
                } while (status == AVAudioEngineManualRenderingStatusCannotDoInCurrentContext
                         && chunk.frameLength == 0 && ++attempts < 8);
                return status == AVAudioEngineManualRenderingStatusSuccess && chunk.frameLength == count ? noErr : (OSStatus)(status ?: -1);
            } running:^BOOL{
                return engine.isRunning;
            }];
            LogInfo(@"AudioPlayer: --no-audio-hw, manual rendering, no output device");
        }
        else {
            if (pump) [NSException raise:NSInternalInconsistencyException format:@"Manual rendering required: %@", manualError];
            LogError(@"AudioPlayer: --no-audio-hw manual rendering unavailable (%@)", manualError);
        }
    }
#endif
    if (!format) {
        double rate = [_engine.outputNode outputFormatForBus:0].sampleRate;
        format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate > 0 ? rate : 44100 channels:2];
    }
    [self setMasterBusFormatOnQueue:format];
    VibeMasterBus *master = _masterBus; // the block captures the pointer, never self
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format
            renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
        *isSilence = NO;
        return VibeMasterBusRender(master, timestamp, frameCount, outputData);
    }];
    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode to:_engine.outputNode format:format];
#endif
}

#if DEBUG
- (void)attachPumpOnQueue:(VibeManualRenderPump *)pump
                   render:(OSStatus (^)(const AudioTimeStamp *timestamp, AVAudioPCMBuffer *chunk, AVAudioFrameCount count))render
                  running:(BOOL (^)(void))running {
    // The pump stands in for the IO thread: the frame-driven mode decodes
    // inline before each slice, and both modes drain after it.
    __weak AudioPlayer *weakSelf = self;
    pump.beforeRender = pump.automatic ? nil : ^{
        AudioPlayer *strongSelf = weakSelf;
        [strongSelf->_voiceBus fillInline];
    };
    pump.afterRender = ^{ [weakSelf drainVoiceBusOnQueue]; };
    [pump attachRender:render running:running queue:_queue];
}
#endif

// The pipeline's format changed: the master bus follows, and the FX chain is
// re-hosted at it. The bus is the source segment's to rebuild.
- (void)setMasterBusFormatOnQueue:(AVAudioFormat *)format {
    _masterFormat = format;
    _masterBus->sampleRate = format.sampleRate;
    _masterBus->channels = format.channelCount;
    [self reconcileFXOnQueue];
}

- (AVAudioFormat *)masterBusFormatOnQueue {
    return _masterFormat;
}

- (void)reconcileFXOnQueue {
    if (!self.fx || !_masterFormat) {
        return;
    }
    BOOL enableFX = _fxEnabled;
#if TARGET_OS_OSX
    enableFX &= !_bitPerfectWanted;
#endif
    [self.fx setConnected:enableFX format:_masterFormat maximumFrameCount:kVibeMasterBusMaxFrames];
    atomic_store_explicit(&_masterBus->chain, self.fx.chain, memory_order_release);
}

- (void)applyLevelTapOnQueue {
    BOOL wanted = _levelsWanted || self.signalProbeWanted;
    if (wanted && !_levelTap && _levelPublisher && _masterFormat) {
        // The final output samples, the only place the bars can follow what
        // is actually heard: after the FX returns re-enter, before --silent.
        _levelTap = [[AudioLevelTap alloc] initWithFormat:_masterFormat publisher:_levelPublisher
                                        normalizationMode:_levelNormalizationMode];
        if (!_levelTap) {
            return;
        }
        atomic_store_explicit(&_masterBus->meter, _levelTap.meter, memory_order_release);
        atomic_store_explicit(&_masterBus->meterWanted, 1, memory_order_seq_cst);
        if (_state == VibePlayerStatePlaying && _voice) {
            [self armSignalProbeOnQueue:@"tap installed during playback"];
        }
    }
    else if (!wanted && _levelTap) {
        [self removeLevelTapOnQueue];
    }
}

#if !TARGET_OS_OSX
// The iOS media-services reset: every audio object is dead and must not be
// messaged. The gate closes first, so a late render writes silence — the
// engine is dead, but the guarantee costs nothing — and the bus goes with
// it, its voices' files having died with the media server. The park and the
// pending open go too: the file handles they would produce are dead, and a
// download without a consumer is waste. createOutputOnQueue rebuilds.
- (void)dropEngineBoundStateOnQueue {
    if (_drainTimer) {
        dispatch_source_cancel(_drainTimer);
        _drainTimer = nil;
    }
    [_retiringVoices removeAllObjects];
    atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
    atomic_store_explicit(&_masterBus->mix, NULL, memory_order_seq_cst);
    [self retireRenderObjectOnQueue:_voiceBus];
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = nil;
    _voice = 0;
    os_unfair_lock_unlock(&_stateLock);
    [self removeLevelTapOnQueue];
    _sourceNode = nil;
    _engine = nil;
    [self refreshOutputAudioActiveOnQueue];
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    [_pendingRequest invalidate];
    [self clearSuccessorOnQueue];
}
#endif

- (void)removeLevelTapOnQueue {
    AudioLevelTap *tap = _levelTap;
    _levelTap = nil;
    atomic_store_explicit(&_masterBus->meterWanted, 0, memory_order_seq_cst);
    atomic_store_explicit(&_masterBus->meter, NULL, memory_order_relaxed);
    [self retireRenderObjectOnQueue:tap];
    [tap remove];
}

// The removal was published before this is called: a render that read the
// object set inRender before that store was seen, and finishes on its own
// within a block's time, so a render seen outside guarantees none is inside.
// A render that does not leave within the bound keeps the object alive in
// the graveyard until an edge sees the render outside.
- (void)retireRenderObjectOnQueue:(id)object {
    VibeMasterBus *master = _masterBus;
    for (int spin = 0; spin < kRetireSpinLimit; spin++) {
        if (!atomic_load_explicit(&master->inRender, memory_order_seq_cst)) {
            [_retiredRenderState removeAllObjects];
            return;
        }
        usleep(kRetireSpinMicroseconds);
    }
    if (object) {
        [_retiredRenderState addObject:object];
    }
}

#if TARGET_OS_OSX
- (BOOL)applyOutputRateOnQueue:(double)rate {
    if (!_outputUnit) {
        return NO;
    }
    if (_masterBus->sampleRate == rate && _outputUnit.format.sampleRate == rate) {
        return YES;
    }
    [self stopOutputOnQueue];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    NSError *error = nil;
    if (![_outputUnit configureFormat:format maximumFrameCount:kVibeMasterBusMaxFrames
                           renderProc:VibeMasterBusRenderProc refCon:_masterBus error:&error]) {
        LogError(@"AudioPlayer: output unit refused %.0f Hz (%@)", rate, error);
        return NO;
    }
    [self setMasterBusFormatOnQueue:format];
    // A bus at the old rate would play at the wrong speed with nothing left
    // to resample it; the callers guarantee nothing audible.
    if (_voiceBus) {
        [self ensureSourceSegmentOnQueueRebuilt:NULL];
    }
    LogInfo(@"AudioPlayer: output unit pulls at %.0f Hz from device %u", rate, _outputUnit.deviceID);
    return YES;
}
#endif

- (BOOL)renderingOnQueue {
#if TARGET_OS_OSX
    return atomic_load_explicit(&_masterBus->gate, memory_order_relaxed) != 0;
#else
    return _engine.isRunning;
#endif
}

- (AVAudioTime *)outputRenderTimeOnQueue {
    if (!_masterFormat) {
        return nil;
    }
    uint64_t frames = atomic_load_explicit(&_masterBus->frames, memory_order_acquire)
            + atomic_load_explicit(&_masterBus->pendingFrames, memory_order_acquire);
    return [AVAudioTime timeWithSampleTime:(AVAudioFramePosition)frames atRate:_masterFormat.sampleRate];
}

- (BOOL)varispeedPresentOnQueue {
    return atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed) != NULL;
}

- (NSTimeInterval)varispeedLatencyOnQueue {
    AudioUnit varispeed = atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed);
    Float64 latency = 0;
    UInt32 size = sizeof(latency);
    if (varispeed) {
        AudioUnitGetProperty(varispeed, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    }
    return latency;
}

- (NSUInteger)hostedUnitCountOnQueue {
    return ([self varispeedPresentOnQueue] ? 1 : 0) + self.fx.hostedUnitCount;
}

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

// Hosts Apple's Varispeed unit at `format` over the bus. TRAP: a directly
// hosted unit defaults to 1156 frames per slice and refuses the output's
// 4096-frame slices with kAudioUnitErr_TooManyFramesToProcess; AVAudioEngine
// set this on every node for us.
- (AudioUnit)hostVarispeedOnQueueWithFormat:(AVAudioFormat *)format {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_FormatConverter, .componentSubType = kAudioUnitSubType_Varispeed,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr || !unit) {
        LogError(@"AudioPlayer: no Varispeed unit");
        return NULL;
    }
    AudioStreamBasicDescription asbd = *format.streamDescription;
    UInt32 maxFrames = kVibeMasterBusMaxFrames;
    AURenderCallbackStruct input = { .inputProc = VibeMasterBusVarispeedInput, .inputProcRefCon = _masterBus };
    OSStatus status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, sizeof(input));
    }
    if (status == noErr) {
        status = AudioUnitInitialize(unit);
    }
    if (status != noErr) {
        LogError(@"AudioPlayer: hosting the Varispeed unit failed (OSStatus %d)", (int)status);
        AudioComponentInstanceDispose(unit);
        return NULL;
    }
    return unit;
}

- (void)disposeVarispeedOnQueue {
    AudioUnit varispeed = atomic_exchange_explicit(&_masterBus->varispeed, NULL, memory_order_seq_cst);
    if (!varispeed) {
        return;
    }
    [self retireRenderObjectOnQueue:nil];
    AudioUnitUninitialize(varispeed);
    AudioComponentInstanceDispose(varispeed);
}

- (BOOL)ensureSourceSegmentOnQueueRebuilt:(BOOL *)rebuilt {
    if (rebuilt) {
        *rebuilt = NO;
    }
    AVAudioFormat *busFormat = _masterFormat;
    if (!busFormat) {
        return NO;
    }
    // The bus always runs at the output's format, so a mode toggle or an
    // output rate change rebuilds it; the varispeed exists only for ordinary
    // playback on macOS, where pitch can leave zero.
#if TARGET_OS_OSX
    BOOL wantVarispeed = ![self bitPerfectOnQueue];
#else
    BOOL wantVarispeed = NO;
#endif
    if (_voiceBus && VibeFormatsMatch(_voiceBus.format, busFormat) && [self varispeedPresentOnQueue] == wantVarispeed) {
        return YES;
    }
    // Every voice dies with the old segment; the callers made sure none was
    // audible. The output must be stopped to rebuild. The bus pointer is
    // written under the lock because the position getter reads it off it.
    [self stopOutputOnQueue];
    if (_voiceBus) {
        AudioVoiceBus *old = _voiceBus;
        atomic_store_explicit(&_masterBus->mix, NULL, memory_order_seq_cst);
        [self retireRenderObjectOnQueue:old];
        // TRAP: the new voice takes the same AVAudioFile, and the old bus's
        // decoder may be inside a read of it — its queued turns retain the
        // bus, not this player — so it is stopped and waited for first;
        // without that both decoders moved the file's position and the new
        // voice ended early.
        [old stopReading];
        os_unfair_lock_lock(&_stateLock);
        _voiceBus = nil;
        os_unfair_lock_unlock(&_stateLock);
        [_retiringVoices removeAllObjects];
        [self unpublishVoiceOnQueue];
    }
    [self disposeVarispeedOnQueue];
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
    AudioUnit varispeed = NULL;
    if (wantVarispeed) {
        varispeed = [self hostVarispeedOnQueueWithFormat:busFormat];
        if (!varispeed) {
            return NO;
        }
    }
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = bus;
    _busSampleRate = busFormat.sampleRate;
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    atomic_store_explicit(&_masterBus->mix, bus.mix, memory_order_release);
    atomic_store_explicit(&_masterBus->varispeed, varispeed, memory_order_release);
    [self applyPitchOnQueue:pitch];
    if (rebuilt) {
        *rebuilt = YES;
    }
    return YES;
}

// The one mapping from the published pitch to the varispeed: a ratio, and
// bypass at zero, because even a ratio of 1.0 is not a pass-through
// (measured: 0.04 on noise) while the unit's own bypass is exact.
- (void)applyPitchOnQueue:(float)pitch {
    AudioUnit varispeed = atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed);
    if (!varispeed) {
        return;
    }
    AudioUnitSetParameter(varispeed, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, 1.0f + pitch / 100.0f, 0);
    UInt32 bypass = pitch == 0;
    AudioUnitSetProperty(varispeed, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, sizeof(bypass));
}

#pragma mark - Starting and stopping

- (BOOL)startOutputOnQueue:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    if (_terminating) {
        return NO;
    }
    _outputIdleStopGeneration++; // playback is starting: cancel any pending idle stop
    if (![self renderingOnQueue]) {
#if TARGET_OS_OSX
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        if (_outputUnit) {
            [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
                [self acquireExclusiveOutputOnQueue];
                return YES; // ownership confirmation is logged by the nested hog phase
            }];
        }
#endif
        // The gate opens before the unit starts, so the first cycle renders.
        atomic_store_explicit(&_masterBus->gate, 1, memory_order_seq_cst);
        if (_outputUnit && !_outputUnit.running) {
            __block NSError *unitError = nil;
            uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            BOOL pulling = [self performDiagnosticPhase:@"output unit start" device:(NSInteger)_outputUnit.deviceID operation:^BOOL{
                return [self->_outputUnit startWithError:&unitError];
            }];
            NSTimeInterval seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt) / NSEC_PER_SEC;
            BOOL slow = seconds > kSlowOutputStartLogThresholdSeconds;
            LogTiming(slow, @"AudioPlayer: %@output start %.3fs (the player queue was blocked for this long)",
                      slow ? @"slow " : @"", seconds);
            if (!pulling) {
                atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
                if (outError) {
                    *outError = unitError;
                }
                return NO;
            }
        }
#else
        __block NSError *startError = nil;
        uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL started = [self performDiagnosticPhase:@"engine start" device:-1 operation:^BOOL{
            return [self->_engine startAndReturnError:&startError];
        }];
        NSTimeInterval seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt) / NSEC_PER_SEC;
        BOOL slow = seconds > kSlowOutputStartLogThresholdSeconds;
        LogTiming(slow, @"AudioPlayer: %@engine start %.3fs (the player queue was blocked for this long)",
                  slow ? @"slow " : @"", seconds);
        if (!started) {
            if (outError) {
                *outError = startError;
            }
            return NO;
        }
        atomic_store_explicit(&_masterBus->gate, 1, memory_order_seq_cst);
#endif
    }
    [self applyLevelTapOnQueue];
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
    return YES;
}

- (void)stopOutputOnQueue {
#if TARGET_OS_OSX
    [_outputUnit stop]; // gate closed and no cycle in flight before the pipeline's own gate closes
#else
    [_engine stop];
#endif
    atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
    [self retireRenderObjectOnQueue:nil];
    for (NSNumber *voice in _retiringVoices) {
        [_voiceBus killVoice:voice.unsignedLongLongValue];
    }
    [self refreshOutputAudioActiveOnQueue];
    [self updateDrainTimerOnQueue];
}

- (void)scheduleOutputIdleStopOnQueue {
    if (_terminating) {
        return;
    }
    uint64_t generation = ++_outputIdleStopGeneration;
    __weak AudioPlayer *weakSelf = self;
    [self scheduleAfterSeconds:kOutputIdleStopDelaySeconds block:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_outputIdleStopGeneration) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_stateLock);
        VibePlayerState state = strongSelf->_state;
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        // Only a still-idle player stops the output. Loading counts as busy,
        // because the in-flight open's settlement wants a warm output. A
        // paused voice keeps its state; resume restarts the output.
        if (state != VibePlayerStateStopped && state != VibePlayerStatePaused) {
            return;
        }
        [strongSelf stopOutputOnQueue];
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
    [bus drainWithOutputRunning:[self renderingOnQueue] handler:^(VibeVoiceID voice, VibeVoiceEvent event) {
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
    BOOL wanted = [self renderingOnQueue] && _voiceBus.occupiedSlotCount > 0;
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

@end
