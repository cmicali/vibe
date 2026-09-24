//
//  AudioOutputUnit.m
//  Vibe
//

#import "AudioOutputUnitInternal.h"
#include <unistd.h>

// A stop waits this long, at most, for a render already inside the callback.
static const useconds_t kStopSpinMicroseconds = 200;
static const int kStopSpinLimit = 500; // 100 ms

#pragma mark - The audio thread

BOOL VibeOutputUnitStateInitialize(VibeOutputUnitState *state, uint32_t channels, uint32_t maxFrames, void *renderBlock) {
    if (channels == 0 || channels > kVibeOutputUnitMaxChannels || maxFrames == 0) {
        return NO;
    }
    AudioBufferList *slice = state->slice;
    if (!slice) {
        slice = calloc(1, sizeof(AudioBufferList) + (kVibeOutputUnitMaxChannels - 1) * sizeof(AudioBuffer));
        if (!slice) {
            return NO;
        }
    }
    slice->mNumberBuffers = channels;
    for (uint32_t c = 0; c < channels; c++) {
        slice->mBuffers[c].mNumberChannels = 1;
    }
    state->slice = slice;
    state->channels = channels;
    state->maxFrames = maxFrames;
    state->renderBlock = renderBlock;
    atomic_store_explicit(&state->frames, 0, memory_order_relaxed);
    atomic_store_explicit(&state->pendingFrames, 0, memory_order_relaxed);
    return YES;
}

void VibeOutputUnitStateFree(VibeOutputUnitState *state) {
    free(state->slice);
    state->slice = NULL;
}

static inline void VibeOutputUnitSilence(AudioBufferList *data, AudioUnitRenderActionFlags *actionFlags) CA_REALTIME_API {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        }
    }
    if (actionFlags) {
        *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }
}

// The one call the compiler cannot check: AVFoundation documents the realtime
// manual-rendering block as safe to call from a render thread, and attributes
// it with nothing. Everything around it is under the error pragma below.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
#endif
static inline AVAudioEngineManualRenderingStatus VibeOutputUnitPull(void *renderBlock, uint32_t frames,
                                                                     AudioBufferList *buffer) CA_REALTIME_API {
    __unsafe_unretained AVAudioEngineManualRenderingBlock block = (__bridge __unsafe_unretained AVAudioEngineManualRenderingBlock)renderBlock;
    OSStatus status = noErr;
    return block(frames, buffer, &status);
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

// Everything the IO thread does. Plain memory and atomics, no call that can
// block; the pragma makes the compiler hold that line.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wfunction-effects"
#endif
static OSStatus VibeOutputUnitRenderCycle(VibeOutputUnitState *state, AudioUnitRenderActionFlags *actionFlags,
                                          const AudioTimeStamp *timestamp, UInt32 frameCount,
                                          AudioBufferList *data) CA_REALTIME_API {
    atomic_store_explicit(&state->inRender, 1, memory_order_seq_cst);
    if (timestamp) {
        atomic_fetch_add_explicit(&state->stampVersion, 1, memory_order_release);
        state->stamp = *timestamp;
        atomic_fetch_add_explicit(&state->stampVersion, 1, memory_order_release);
    }
    if (!data || !atomic_load_explicit(&state->gate, memory_order_seq_cst) || !state->renderBlock
            || data->mNumberBuffers < state->channels) {
        if (data) {
            VibeOutputUnitSilence(data, actionFlags);
        }
        atomic_store_explicit(&state->inRender, 0, memory_order_release);
        return noErr;
    }
    // Pull in slices no larger than the block accepts, each pointed straight
    // into the HAL's buffers; a refused slice is retried, then silence.
    uint64_t frames = atomic_load_explicit(&state->frames, memory_order_relaxed);
    BOOL dropped = NO, rendered = NO;
    for (UInt32 offset = 0; offset < frameCount; ) {
        UInt32 count = frameCount - offset < state->maxFrames ? frameCount - offset : state->maxFrames;
        AudioBufferList *slice = state->slice;
        for (uint32_t c = 0; c < state->channels; c++) {
            slice->mBuffers[c].mData = (uint8_t *)data->mBuffers[c].mData + offset * sizeof(float);
            slice->mBuffers[c].mDataByteSize = count * (UInt32)sizeof(float);
        }
        atomic_store_explicit(&state->pendingFrames, count, memory_order_release);
        AVAudioEngineManualRenderingStatus status = AVAudioEngineManualRenderingStatusCannotDoInCurrentContext;
        for (int attempt = 0; attempt <= kVibeOutputUnitRenderRetries
                && status == AVAudioEngineManualRenderingStatusCannotDoInCurrentContext; attempt++) {
            status = VibeOutputUnitPull(state->renderBlock, count, slice);
        }
        if (status == AVAudioEngineManualRenderingStatusSuccess) {
            frames += count;
            atomic_store_explicit(&state->frames, frames, memory_order_release);
            rendered = YES;
        }
        else {
            for (uint32_t c = 0; c < state->channels; c++) {
                memset(slice->mBuffers[c].mData, 0, slice->mBuffers[c].mDataByteSize);
            }
            dropped = YES;
        }
        atomic_store_explicit(&state->pendingFrames, 0, memory_order_release);
        offset += count;
    }
    // Buffers past the format's channels, on a wider device, stay silent.
    for (UInt32 b = state->channels; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        }
    }
    if (dropped) {
        atomic_fetch_add_explicit(&state->dropouts, 1, memory_order_relaxed);
    }
    if (!rendered && actionFlags) {
        *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    atomic_store_explicit(&state->inRender, 0, memory_order_release);
    return noErr;
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

OSStatus VibeOutputUnitRender(void *refCon, AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              UInt32 bus, UInt32 frameCount, AudioBufferList *data) {
    return VibeOutputUnitRenderCycle((VibeOutputUnitState *)refCon, actionFlags, timestamp, frameCount, data);
}

#pragma mark - The unit

@implementation AudioOutputUnit {
    AudioUnit _unit;
    VibeOutputUnitState *_state;
    AVAudioEngineManualRenderingBlock _renderBlock; // the retained copy the struct points at
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_HALOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component || AudioComponentInstanceNew(component, &_unit) != noErr || !_unit) {
        return nil;
    }
    UInt32 on = 1, off = 0;
    AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, sizeof(on));
    AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, sizeof(off));
    _state = calloc(1, sizeof(VibeOutputUnitState));
    AURenderCallbackStruct callback = { .inputProc = VibeOutputUnitRender, .inputProcRefCon = _state };
    AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    _deviceID = kAudioObjectUnknown;
    return self;
}

- (void)dealloc {
    if (_unit) {
        [self stop];
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
    }
    if (_state) {
        VibeOutputUnitStateFree(_state);
        free(_state);
    }
}

- (AudioUnit)audioUnit {
    return _unit;
}

- (uint64_t)dropouts {
    return atomic_load_explicit(&_state->dropouts, memory_order_relaxed);
}

static double VibeSecondsOfLatency(AudioDeviceID device, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope,
                                   AudioObjectID object, double rate) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 frames = 0, size = sizeof(frames);
    if (AudioObjectGetPropertyData(object ?: device, &address, 0, NULL, &size, &frames) != noErr || rate <= 0) {
        return 0;
    }
    return frames / rate;
}

- (OSStatus)bindToDevice:(AudioDeviceID)deviceID {
    OSStatus status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &deviceID, sizeof(deviceID));
    if (status != noErr) {
        return status;
    }
    _deviceID = deviceID;
    // The device's own reckoning of when a rendered sample is heard, for the
    // diagnostics that used to read the engine's output node.
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(deviceID, &rateAddress, 0, NULL, &size, &rate);
    AudioObjectPropertyAddress streamsAddress = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioStreamID stream = kAudioObjectUnknown;
    size = sizeof(stream);
    AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, NULL, &size, &stream);
    _presentationLatency = VibeSecondsOfLatency(deviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0, rate)
            + VibeSecondsOfLatency(deviceID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0, rate)
            + (stream != kAudioObjectUnknown
               ? VibeSecondsOfLatency(deviceID, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, stream, rate) : 0);
    return noErr;
}

static NSError *VibeOutputUnitError(OSStatus status, NSString *what) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (OSStatus %d)", what, (int)status]}];
}

- (BOOL)configureFormat:(AVAudioFormat *)format maximumFrameCount:(AVAudioFrameCount)maximumFrameCount
            renderBlock:(AVAudioEngineManualRenderingBlock)renderBlock error:(NSError **)error {
    NSParameterAssert(!self.running);
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved);
    AudioUnitUninitialize(_unit);
    AudioStreamBasicDescription description = *format.streamDescription;
    OSStatus status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &description, sizeof(description));
    if (status != noErr) {
        if (error) *error = VibeOutputUnitError(status, @"Could not set the output unit's format");
        return NO;
    }
    _renderBlock = [renderBlock copy];
    if (!VibeOutputUnitStateInitialize(_state, format.channelCount, maximumFrameCount, (__bridge void *)_renderBlock)) {
        if (error) *error = VibeOutputUnitError(kAudioUnitErr_FormatNotSupported, @"Unsupported output unit format");
        return NO;
    }
    status = AudioUnitInitialize(_unit);
    if (status != noErr) {
        if (error) *error = VibeOutputUnitError(status, @"Could not initialize the output unit");
        return NO;
    }
    _format = format;
    return YES;
}

- (BOOL)startWithError:(NSError **)error {
    if (_running) {
        return YES;
    }
    atomic_store_explicit(&_state->gate, 1, memory_order_release);
    OSStatus status = AudioOutputUnitStart(_unit);
    if (status != noErr) {
        atomic_store_explicit(&_state->gate, 0, memory_order_release);
        if (error) *error = VibeOutputUnitError(status, @"Could not start the output unit");
        return NO;
    }
    _running = YES;
    return YES;
}

- (void)stop {
    atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
    if (_running) {
        AudioOutputUnitStop(_unit);
        _running = NO;
    }
    // The gate store and the callback's gate load are both seq_cst, so a
    // cycle that read the gate open has inRender set before this read sees
    // it clear; it finishes on its own within a buffer's time.
    for (int spin = 0; spin < kStopSpinLimit && atomic_load_explicit(&_state->inRender, memory_order_seq_cst); spin++) {
        usleep(kStopSpinMicroseconds);
    }
}

- (AVAudioTime *)renderTime {
    double rate = _format.sampleRate;
    uint64_t frames = atomic_load_explicit(&_state->frames, memory_order_acquire)
            + atomic_load_explicit(&_state->pendingFrames, memory_order_acquire);
    return [AVAudioTime timeWithSampleTime:(AVAudioFramePosition)frames atRate:rate > 0 ? rate : 1];
}

- (AudioTimeStamp)lastIOTimeStamp {
    AudioTimeStamp stamp = {0};
    for (int attempt = 0; attempt < 3; attempt++) {
        uint32_t version = atomic_load_explicit(&_state->stampVersion, memory_order_acquire);
        stamp = _state->stamp;
        if (!(version & 1) && atomic_load_explicit(&_state->stampVersion, memory_order_acquire) == version) {
            return stamp;
        }
    }
    return stamp;
}

@end
