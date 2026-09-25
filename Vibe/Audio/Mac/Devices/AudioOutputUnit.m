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

BOOL VibeOutputUnitStateInitialize(VibeOutputUnitState *state, uint32_t channels,
                                   VibeOutputRenderProc renderProc, void *renderRefCon) {
    if (channels == 0) {
        return NO;
    }
    state->channels = channels;
    state->renderProc = renderProc;
    state->renderRefCon = renderRefCon;
    return YES;
}

// Zeroes every buffer from `first` on.
static inline void VibeOutputUnitZero(AudioBufferList *data, UInt32 first) CA_REALTIME_API {
    for (UInt32 b = first; b < data->mNumberBuffers; b++) {
        if (data->mBuffers[b].mData) {
            memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        }
    }
}

// Everything the IO thread does. Plain memory and atomics, no call that can
// block; the pragma makes the compiler hold that line, the proc's own
// attribute included.
VIBE_REALTIME_CHECKED_BEGIN
static OSStatus VibeOutputUnitRenderCycle(VibeOutputUnitState *state, AudioUnitRenderActionFlags *actionFlags,
                                          const AudioTimeStamp *timestamp, UInt32 frameCount,
                                          AudioBufferList *data) CA_REALTIME_API {
    atomic_store_explicit(&state->inRender, 1, memory_order_seq_cst);
    if (!data || !atomic_load_explicit(&state->gate, memory_order_seq_cst) || !state->renderProc
            || data->mNumberBuffers < state->channels) {
        if (data) {
            VibeOutputUnitZero(data, 0);
            if (actionFlags) {
                *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
            }
        }
        atomic_store_explicit(&state->inRender, 0, memory_order_release);
        return noErr;
    }
    // The whole cycle, straight into the HAL's buffers; a cycle the proc
    // fails is silence and a dropout.
    if (state->renderProc(state->renderRefCon, timestamp, frameCount, data) != noErr) {
        VibeOutputUnitZero(data, 0);
        atomic_fetch_add_explicit(&state->dropouts, 1, memory_order_relaxed);
        if (actionFlags) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
    }
    atomic_store_explicit(&state->inRender, 0, memory_order_release);
    return noErr;
}
VIBE_REALTIME_END

// The cost of every cycle the gate was open for is measured here, around the
// checked function: the clock read is not on the checker's list, and it is a
// commpage read that blocks on nothing.
OSStatus VibeOutputUnitRender(void *refCon, AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              UInt32 bus, UInt32 frameCount, AudioBufferList *data) {
    VibeOutputUnitState *state = refCon;
    BOOL open = atomic_load_explicit(&state->gate, memory_order_relaxed) != 0;
    uint64_t began = open ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    OSStatus status = VibeOutputUnitRenderCycle(state, actionFlags, timestamp, frameCount, data);
    if (open) {
        uint64_t nanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began;
        atomic_fetch_add_explicit(&state->cycles, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->renderNanos, nanos, memory_order_relaxed);
        if (nanos > atomic_load_explicit(&state->renderMaxNanos, memory_order_relaxed)) {
            atomic_store_explicit(&state->renderMaxNanos, nanos, memory_order_relaxed);
        }
    }
    return status;
}

void VibeOutputUnitStateClearCounters(VibeOutputUnitState *state) {
    atomic_store_explicit(&state->dropouts, 0, memory_order_relaxed);
    atomic_store_explicit(&state->cycles, 0, memory_order_relaxed);
    atomic_store_explicit(&state->renderNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&state->renderMaxNanos, 0, memory_order_relaxed);
}

#pragma mark - The unit

@implementation AudioOutputUnit {
    AudioUnit _unit;
    VibeOutputUnitState *_state;
    BOOL _initialized;
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
    free(_state);
}

- (AudioUnit)audioUnit {
    return _unit;
}

- (uint64_t)dropouts {
    return atomic_load_explicit(&_state->dropouts, memory_order_relaxed);
}

- (uint64_t)renderCycles {
    return atomic_load_explicit(&_state->cycles, memory_order_relaxed);
}

- (double)renderMeanMicroseconds {
    uint64_t cycles = atomic_load_explicit(&_state->cycles, memory_order_relaxed);
    return cycles ? (double)atomic_load_explicit(&_state->renderNanos, memory_order_relaxed) / cycles / 1000.0 : 0;
}

- (double)renderMaxMicroseconds {
    return atomic_load_explicit(&_state->renderMaxNanos, memory_order_relaxed) / 1000.0;
}

- (void)clearCounters {
    VibeOutputUnitStateClearCounters(_state);
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
    NSParameterAssert(!self.running);
    // AUHAL takes a new device cleanly only across an initialize, and a bind
    // at the same rate is not followed by a reconfigure.
    if (_initialized) {
        AudioUnitUninitialize(_unit);
    }
    OSStatus status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &deviceID, sizeof(deviceID));
    if (_initialized && AudioUnitInitialize(_unit) != noErr) {
        _initialized = NO;
    }
    if (status != noErr) {
        return status;
    }
    _deviceID = deviceID;
    // The device's own reckoning of when a rendered sample is heard, for the
    // diagnostics.
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

- (NSTimeInterval)bufferLatency {
    if (_deviceID == kAudioObjectUnknown) {
        return 0;
    }
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(_deviceID, &rateAddress, 0, NULL, &size, &rate);
    return VibeSecondsOfLatency(_deviceID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, 0, rate);
}

static NSError *VibeOutputUnitError(OSStatus status, NSString *what) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (OSStatus %d)", what, (int)status]}];
}

- (BOOL)configureFormat:(AVAudioFormat *)format renderProc:(VibeOutputRenderProc)renderProc refCon:(void *)refCon
                  error:(NSError **)error {
    NSParameterAssert(!self.running);
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved);
    AudioUnitUninitialize(_unit);
    _initialized = NO;
    AudioStreamBasicDescription description = *format.streamDescription;
    OSStatus status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &description, sizeof(description));
    if (status != noErr) {
        if (error) *error = VibeOutputUnitError(status, @"Could not set the output unit's format");
        return NO;
    }
    if (!VibeOutputUnitStateInitialize(_state, format.channelCount, renderProc, refCon)) {
        if (error) *error = VibeOutputUnitError(kAudioUnitErr_FormatNotSupported, @"Unsupported output unit format");
        return NO;
    }
    status = AudioUnitInitialize(_unit);
    if (status != noErr) {
        if (error) *error = VibeOutputUnitError(status, @"Could not initialize the output unit");
        return NO;
    }
    _initialized = YES;
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


@end
