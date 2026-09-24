//
//  AudioPlayer+Graph.m
//  Vibe
//

#import "AudioPlayer+Graph.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#import "CoreAudioUtil.h"
#endif
#if DEBUG
#import "VibeManualRenderPump.h"
#endif
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <unistd.h>

// Give the next track time to open before releasing the idle output.
static const NSTimeInterval kOutputIdleStopDelaySeconds = 6.0;
// The hardware drain: the bus reports its events within this of their render.
static const uint64_t kDrainIntervalNanos = 10 * NSEC_PER_MSEC;
// An output start holding the player queue longer than this is worth a line
// even in stable builds.
static const NSTimeInterval kSlowOutputStartLogThresholdSeconds = 0.25;
// A render already inside the pipeline leaves within a block's time; the
// wait is bounded, as the output unit's stop is.
static const useconds_t kRenderLeaveSpinMicroseconds = 200;
static const int kRenderLeaveSpinLimit = 500; // 100 ms

#pragma mark - The master bus

// What the audio thread reads. Writers: the queue (the pointers, with the
// output stopped or withdrawn before the render is waited out; the gate and
// the flags), the render (the counters, the stamp and inRender).
struct VibeMasterBus {
    _Atomic int32_t gate;            // 1 while the output may render
    _Atomic int32_t inRender;        // 1 while the render is inside the pipeline
    _Atomic uint64_t frames;         // the output timeline: frames rendered
    _Atomic uint32_t pendingFrames;  // the slice in flight
    _Atomic int32_t silent;          // --silent: the meter sees the signal, the device zeros
    _Atomic(VibeVoiceMix *) mix;     // the bus; NULL until the first settlement
    _Atomic(AudioUnit) varispeed;    // ordinary playback on macOS; NULL otherwise
    _Atomic(VibeFXChain *) chain;    // the FX segment, which decides for itself whether it is connected
    _Atomic(VibeLevelMeter *) meter; // the equalizer's, while wanted
    AudioTimeStamp stamp;            // the slice's own stamp, which the bus reads through the varispeed's pull
    double hostTicksPerFrame;
    uint32_t channels;               // the output's, 1 or 2: what a slice carries; the app's carriers are stereo
};

// A stereo slice list the render builds on its stack.
typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} VibeMasterBusStereoList;

// The one call the compiler cannot check: the varispeed's render, which
// AudioToolbox documents as the render thread's own entry point and
// attributes with nothing.
VIBE_REALTIME_UNCHECKED_BEGIN
static inline OSStatus VibeMasterBusRenderVarispeed(AudioUnit varispeed, const AudioTimeStamp *stamp, UInt32 frames,
                                                    AudioBufferList *data) CA_REALTIME_API {
    AudioUnitRenderActionFlags flags = 0;
    return AudioUnitRender(varispeed, &flags, stamp, 0, frames, data);
}
VIBE_REALTIME_END

// Everything the audio thread does. Plain memory and atomics, no call that
// can block; the pragma makes the compiler hold that line.
VIBE_REALTIME_CHECKED_BEGIN
static inline void VibeMasterBusZero(AudioBufferList *data, UInt32 offset, UInt32 frames) CA_REALTIME_API {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset((float *)data->mBuffers[b].mData + offset, 0, frames * sizeof(float));
        }
    }
}

// The varispeed's input: the bus, for whatever count the unit asks, stamped
// with the slice's own stamp — the unit forwards a stamp of its own whose
// host time is not the cycle's.
static OSStatus VibeMasterBusVarispeedInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *stamp,
                                            UInt32 bus, UInt32 frames, AudioBufferList *data) CA_REALTIME_API {
    VibeMasterBus *master = refCon;
    VibeVoiceMix *mix = atomic_load_explicit(&master->mix, memory_order_relaxed);
    if (!mix || !data) {
        if (data) {
            VibeMasterBusZero(data, 0, frames);
        }
        if (flags) {
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }
    BOOL silence = NO;
    OSStatus status = VibeVoiceBusRender(mix, &silence, &master->stamp, frames, data);
    if (silence && flags) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return status;
}

// One slice, no larger than a hosted unit accepts, straight into `data` at
// `offset`.
static OSStatus VibeMasterBusRenderSlice(VibeMasterBus *master, const AudioTimeStamp *hostStamp, UInt32 offset, UInt32 frames,
                                         AudioBufferList *data) CA_REALTIME_API {
    VibeMasterBusStereoList slice = { master->channels, {{0}} };
    for (UInt32 c = 0; c < master->channels; c++) {
        slice.mBuffers[c].mNumberChannels = 1;
        slice.mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        slice.mBuffers[c].mData = (float *)data->mBuffers[c].mData + offset;
    }
    AudioBufferList *list = (AudioBufferList *)&slice;
    // The stamp every stage sees: sample time on the output timeline, host
    // time from the carrier's cycle when it has one, advanced for a later
    // slice of it.
    uint64_t rendered = atomic_load_explicit(&master->frames, memory_order_relaxed);
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = (Float64)rendered;
    stamp.mFlags = kAudioTimeStampSampleTimeValid;
    if (hostStamp && (hostStamp->mFlags & kAudioTimeStampHostTimeValid)) {
        stamp.mHostTime = hostStamp->mHostTime + (UInt64)(offset * master->hostTicksPerFrame);
        stamp.mFlags |= kAudioTimeStampHostTimeValid;
    }
    master->stamp = stamp;
    atomic_store_explicit(&master->pendingFrames, frames, memory_order_release);
    OSStatus status = noErr;
    VibeVoiceMix *mix = atomic_load_explicit(&master->mix, memory_order_relaxed);
    AudioUnit varispeed = atomic_load_explicit(&master->varispeed, memory_order_relaxed);
    if (!mix) {
        VibeMasterBusZero(list, 0, frames);
    }
    else if (varispeed) {
        status = VibeMasterBusRenderVarispeed(varispeed, &stamp, frames, list);
    }
    else {
        BOOL silence = NO;
        status = VibeVoiceBusRender(mix, &silence, &stamp, frames, list);
    }
    VibeFXChain *chain = atomic_load_explicit(&master->chain, memory_order_relaxed);
    if (chain) {
        VibeFXChainRender(chain, &stamp, frames, list);
    }
    VibeLevelMeter *meter = atomic_load_explicit(&master->meter, memory_order_seq_cst);
    if (meter) {
        float *channels[2] = { list->mBuffers[0].mData, list->mBuffers[master->channels - 1].mData };
        VibeLevelMeterRender(meter, channels, master->channels, frames, &stamp);
    }
    if (atomic_load_explicit(&master->silent, memory_order_relaxed)) {
        VibeMasterBusZero(list, 0, frames);
    }
    atomic_store_explicit(&master->frames, rendered + frames, memory_order_release);
    atomic_store_explicit(&master->pendingFrames, 0, memory_order_release);
    return status;
}

// The pipeline over `data`'s first buffers — the output's channels — in
// slices of at most kVibeMasterBusMaxFrames, whatever count the carrier
// hands it; any further buffers stay silent.
static OSStatus VibeMasterBusRender(VibeMasterBus *master, const AudioTimeStamp *hostStamp, UInt32 frames,
                                    AudioBufferList *data) CA_REALTIME_API {
    atomic_store_explicit(&master->inRender, 1, memory_order_seq_cst);
    OSStatus status = noErr;
    BOOL usable = atomic_load_explicit(&master->gate, memory_order_seq_cst) && data && frames > 0
            && master->channels > 0 && data->mNumberBuffers >= master->channels;
    for (UInt32 c = 0; usable && c < master->channels; c++) {
        usable = data->mBuffers[c].mData != NULL;
    }
    if (!usable) {
        if (data) {
            VibeMasterBusZero(data, 0, frames);
        }
    }
    else {
        for (UInt32 offset = 0; offset < frames; ) {
            UInt32 count = frames - offset < kVibeMasterBusMaxFrames ? frames - offset : kVibeMasterBusMaxFrames;
            OSStatus sliceStatus = VibeMasterBusRenderSlice(master, hostStamp, offset, count, data);
            if (sliceStatus != noErr) {
                status = sliceStatus;
            }
            offset += count;
        }
        for (UInt32 b = master->channels; b < data->mNumberBuffers; b++) {
            if (data->mBuffers[b].mData) {
                memset(data->mBuffers[b].mData, 0, frames * sizeof(float));
            }
        }
    }
    atomic_store_explicit(&master->inRender, 0, memory_order_release);
    return status;
}
VIBE_REALTIME_END

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
    // The FX chain decides for itself whether it is connected; the pointer
    // stands for the player's life.
    atomic_store_explicit(&_masterBus->chain, self.fx.chain, memory_order_release);
#if DEBUG
    // --no-audio-hw, for testing: no carrier at all, on either platform. The
    // pump stands in for the IO thread, calling the pipeline at real-time
    // pace or, frame-driven, when a test asks. Starting the hardware IO —
    // even muted — counts as the Mac playing audio, which is enough for
    // macOS to yank auto-switching AirPods over from another device mid-test.
    // --silent, for testing: the pipeline renders normally, the meter sees
    // the signal, and the buffers are zeroed on their way to the device,
    // which still gets opened and driven.
    VibeManualRenderPump *pump = _manualPump;
    BOOL noAudioHW = pump != nil || [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    atomic_store_explicit(&_masterBus->silent, [NSProcessInfo.processInfo.arguments containsObject:@"--silent"] ? 1 : 0,
                          memory_order_relaxed);
    if (noAudioHW) {
        AVAudioFormat *format = pump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
        if (!pump) {
            pump = [[VibeManualRenderPump alloc] initWithFormat:format automatic:YES];
            _manualPump = pump;
        }
        // The pump is attached before the format lands: the format's FX
        // reconcile schedules its ramps through the pump, which needs its
        // queue by then. The gate is closed, so the paced pump renders
        // silence until a start.
        VibeMasterBus *master = _masterBus; // the blocks capture the pointer, never self
        [self attachPumpOnQueue:pump render:^OSStatus(AVAudioPCMBuffer *chunk, AVAudioFrameCount count) {
            chunk.frameLength = count;
            return VibeMasterBusRender(master, NULL, count, chunk.mutableAudioBufferList);
        } running:^BOOL{
            return atomic_load_explicit(&master->gate, memory_order_relaxed) != 0;
        }];
        [self setMasterBusFormatOnQueue:format];
        LogInfo(@"AudioPlayer: --no-audio-hw, no output device");
        return;
    }
#endif
#if TARGET_OS_OSX
    // Vibe hosts the output: the unit's callback pulls the pipeline into the
    // device. It begins on the system default at that device's rate; the
    // saved device binds asynchronously through the checked device-switch
    // path.
    _outputUnit = [[AudioOutputUnit alloc] init];
    if (!_outputUnit) {
        LogError(@"AudioPlayer: no HAL output unit; nothing will play");
    }
    AudioDeviceID deviceID = kAudioObjectUnknown;
    if ([CoreAudioUtil readSystemDefaultOutputDeviceID:&deviceID] && deviceID != kAudioObjectUnknown) {
        [self setOutputUnitDevice:deviceID];
    }
    [self followOutputDeviceRateOnQueue];
    if (!_masterFormat) {
        // No unit, or an unreadable or refused rate: the pipeline still has a format.
        [self setMasterBusFormatOnQueue:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2]];
    }
#else
    // iOS: the engine is the carrier and nothing else — one source node,
    // whose block is the pipeline, into its output node.
    _engine = [[AVAudioEngine alloc] init];
    double rate = [_engine.outputNode outputFormatForBus:0].sampleRate;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate > 0 ? rate : 44100 channels:2];
    [self setMasterBusFormatOnQueue:format];
    VibeMasterBus *master = _masterBus; // the block captures the pointer, never self
    AVAudioSourceNode *sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format
            renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
        *isSilence = NO;
        return VibeMasterBusRender(master, timestamp, frameCount, outputData);
    }];
    [_engine attachNode:sourceNode];
    [_engine connect:sourceNode to:_engine.outputNode format:format];
#endif
}

#if DEBUG
- (void)attachPumpOnQueue:(VibeManualRenderPump *)pump render:(VibeManualRenderBlock)render running:(BOOL (^)(void))running {
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

// The pipeline's format changed: the master bus follows, the FX chain is
// re-hosted at it, and the meter, which analyzes at one rate for its life,
// is replaced. The bus is the source segment's to rebuild.
- (void)setMasterBusFormatOnQueue:(AVAudioFormat *)format {
    _masterFormat = format;
    _masterBus->channels = format.channelCount < 2 ? 1 : 2;
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    _masterBus->hostTicksPerFrame = 1e9 * timebase.denom / ((double)timebase.numer * format.sampleRate);
    [self reconcileFXOnQueue];
    if (_levelTap && _levelTap.sampleRate != format.sampleRate) {
        [self dropLevelTapOnQueue];
        [self applyLevelTapOnQueue];
    }
}

- (AVAudioFormat *)masterBusFormatOnQueue {
    return _masterFormat;
}

- (BOOL)fxWantedOnQueue {
    return _fxEnabled && ![self bitPerfectOnQueue];
}

- (void)reconcileFXOnQueue {
    if (!self.fx || !_masterFormat) {
        return;
    }
    [self.fx setConnected:[self fxWantedOnQueue] format:_masterFormat maximumFrameCount:kVibeMasterBusMaxFrames];
}

- (void)applyLevelTapOnQueue {
    BOOL wanted = _levelsWanted || self.signalProbeWanted;
    if (wanted) {
        if (!_levelTap && _levelPublisher && _masterFormat) {
            // The final output samples, the only place the bars can follow
            // what is actually heard: after the FX returns re-enter, before
            // --silent.
            _levelTap = [[AudioLevelTap alloc] initWithFormat:_masterFormat publisher:_levelPublisher
                                            normalizationMode:_levelNormalizationMode];
        }
        if (!_levelTap || _levelTap.installed) {
            return;
        }
        [_levelTap install];
        atomic_store_explicit(&_masterBus->meter, _levelTap.meter, memory_order_seq_cst);
        if (_state == VibePlayerStatePlaying && _voice) {
            [self armSignalProbeOnQueue:@"tap installed during playback"];
        }
    }
    else if (_levelTap.installed) {
        // The pointer goes first; a render already inside publishes once
        // more into the session this ends, which the publisher drops.
        atomic_store_explicit(&_masterBus->meter, NULL, memory_order_seq_cst);
        [_levelTap remove];
    }
}

- (void)dropLevelTapOnQueue {
    AudioLevelTap *tap = _levelTap;
    if (!tap) {
        return;
    }
    atomic_store_explicit(&_masterBus->meter, NULL, memory_order_seq_cst);
    [self waitForRenderToLeaveOnQueue];
    [tap remove];
    _levelTap = nil;
}

// The withdrawal was published before this is called: a render that read
// the object set inRender before that store was seen, and finishes on its
// own within a block's time, so a render seen outside guarantees none is
// inside.
- (void)waitForRenderToLeaveOnQueue {
    VibeMasterBus *master = _masterBus;
    if (!master) {
        return;
    }
    for (int spin = 0; spin < kRenderLeaveSpinLimit; spin++) {
        if (!atomic_load_explicit(&master->inRender, memory_order_seq_cst)) {
            return;
        }
        usleep(kRenderLeaveSpinMicroseconds);
    }
    LogError(@"AudioPlayer: a render did not leave the pipeline within %d ms",
             (int)(kRenderLeaveSpinLimit * kRenderLeaveSpinMicroseconds / 1000));
}

// The bus leaves the render and dies with every voice; the caller decided
// nothing was audible.
- (void)dropVoiceBusOnQueue {
    AudioVoiceBus *old = _voiceBus;
    if (!old) {
        return;
    }
    atomic_store_explicit(&_masterBus->mix, NULL, memory_order_seq_cst);
    [self waitForRenderToLeaveOnQueue];
    // TRAP: the new voice takes the same AVAudioFile, and the old bus's
    // decoder may be inside a read of it — its queued turns retain the bus,
    // not this player — so it is stopped and waited for first; without that
    // both decoders moved the file's position and the new voice ended early.
    [old stopReading];
    os_unfair_lock_lock(&_stateLock);
    _voiceBus = nil;
    os_unfair_lock_unlock(&_stateLock);
    [_retiringVoices removeAllObjects];
    [self unpublishVoiceOnQueue];
}

#if !TARGET_OS_OSX
// The iOS media-services reset: every audio object is dead and must not be
// messaged. The gate closes first, so a late render writes silence — the
// engine is dead, but the guarantee costs nothing — and the bus and the
// meter go with it, the voices' files having died with the media server.
// The park and the pending open go too: the file handles they would produce
// are dead, and a download without a consumer is waste. createOutputOnQueue
// rebuilds.
- (void)dropEngineBoundStateOnQueue {
    if (_drainTimer) {
        dispatch_source_cancel(_drainTimer);
        _drainTimer = nil;
    }
    atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
    [self dropVoiceBusOnQueue];
    [self dropLevelTapOnQueue];
    _engine = nil;
    [self refreshOutputAudioActiveOnQueue];
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    [_pendingRequest invalidate];
    [self clearSuccessorOnQueue];
}
#endif

#if TARGET_OS_OSX
- (BOOL)applyOutputRateOnQueue:(double)rate {
    if (!_outputUnit) {
        return NO;
    }
    if (_masterFormat.sampleRate == rate && _outputUnit.format.sampleRate == rate) {
        return YES;
    }
    [self stopOutputOnQueue];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    NSError *error = nil;
    if (![_outputUnit configureFormat:format renderProc:VibeMasterBusRenderProc refCon:_masterBus error:&error]) {
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
    // The engine can stop itself on a configuration change, so its own state
    // is the fact while it is the carrier; under the pump the gate is.
    return _engine ? _engine.isRunning : atomic_load_explicit(&_masterBus->gate, memory_order_relaxed) != 0;
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
    return VibeAudioUnitSeconds(atomic_load_explicit(&_masterBus->varispeed, memory_order_relaxed), kAudioUnitProperty_Latency);
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

- (void)disposeVarispeedOnQueue {
    AudioUnit varispeed = atomic_exchange_explicit(&_masterBus->varispeed, NULL, memory_order_seq_cst);
    if (!varispeed) {
        return;
    }
    [self waitForRenderToLeaveOnQueue];
    VibeDisposeAudioUnit(&varispeed);
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
    [self dropVoiceBusOnQueue];
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
        AURenderCallbackStruct input = { .inputProc = VibeMasterBusVarispeedInput, .inputProcRefCon = _masterBus };
        if (!VibeHostAudioUnit(&varispeed, kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed, busFormat.streamDescription,
                               kVibeMasterBusMaxFrames, input, nil)) {
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
        NSInteger device = -1;
#if TARGET_OS_OSX
        device = _outputUnit ? (NSInteger)_outputUnit.deviceID : -1;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
        if (_outputUnit) {
            [self performDiagnosticPhase:@"exclusive setup" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
                [self acquireExclusiveOutputOnQueue];
                return YES; // ownership confirmation is logged by the nested hog phase
            }];
        }
#endif
#endif
        // The gate opens before the carrier starts, so its first cycle
        // renders; a carrier that refuses closes it again. Under the pump
        // there is no carrier, and the open gate is the start.
        atomic_store_explicit(&_masterBus->gate, 1, memory_order_seq_cst);
        __block NSError *error = nil;
        uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        BOOL started = [self performDiagnosticPhase:@"output start" device:device operation:^BOOL{
#if TARGET_OS_OSX
            return !self->_outputUnit || self->_outputUnit.running || [self->_outputUnit startWithError:&error];
#else
            return !self->_engine || [self->_engine startAndReturnError:&error];
#endif
        }];
        NSTimeInterval seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt) / NSEC_PER_SEC;
        BOOL slow = seconds > kSlowOutputStartLogThresholdSeconds;
        LogTiming(slow, @"AudioPlayer: %@output start %.3fs (the player queue was blocked for this long)",
                  slow ? @"slow " : @"", seconds);
        if (!started) {
            atomic_store_explicit(&_masterBus->gate, 0, memory_order_seq_cst);
            if (outError) {
                *outError = error;
            }
            return NO;
        }
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
    [self waitForRenderToLeaveOnQueue];
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
    [self noteDrainOnQueue];
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
