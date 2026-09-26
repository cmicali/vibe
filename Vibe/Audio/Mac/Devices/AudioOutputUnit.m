//
//  AudioOutputUnit.m
//  Vibe
//

#import "AudioOutputUnitInternal.h"
#import "CoreAudioUtil.h"
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

@interface AudioOutputUnit ()
@property (atomic, copy, readwrite, nullable) NSArray<NSNumber *> *channelMap;
@end

@implementation AudioOutputUnit {
    AudioUnit _unit;
    VibeOutputUnitState *_state;
    dispatch_queue_t _halQueue;
    // Player-queue confined: the state the queued HAL work is headed for.
    AudioDeviceID _deviceID;
    AVAudioFormat *_format;
    BOOL _running;
    _Atomic uint64_t _runGeneration;
    // HAL-queue confined.
    BOOL _initialized;
    OSStatus _bindStatus;       // the last bind's refusal, until a bind lands
    OSStatus _configureStatus;  // the last configure's refusal, until one lands
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
    // Default QoS, as the player queue: the waits here are for a device's IO
    // thread, and the player queue is the only thing that ever waits on this.
    _halQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.outputUnit", DISPATCH_QUEUE_SERIAL);
    return self;
}

// Every queued block retains the unit, so none is pending here, and this may
// run on the unit's own queue: it must not wait on it.
- (void)dealloc {
    if (_unit) {
        atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
        [self halStopUnit];
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
    }
    free(_state);
}

- (uint64_t)runGeneration {
    return atomic_load_explicit(&_runGeneration, memory_order_seq_cst);
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

- (VibeOutputUnitState *)state {
    return _state;
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

static NSError *VibeOutputUnitError(OSStatus status, NSString *what) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (OSStatus %d)", what, (int)status]}];
}

static double VibeMillisecondsSinceUptime(uint64_t began) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6;
}

#pragma mark Player-queue API

- (OSStatus)bindToDevice:(AudioDeviceID)deviceID {
    NSParameterAssert(!_running);
    if ([CoreAudioUtil deviceIsConfirmedDead:deviceID]) {
        return kAudioHardwareBadDeviceError;
    }
    _deviceID = deviceID;
    dispatch_async(_halQueue, ^{ [self halBindToDevice:deviceID]; });
    return noErr;
}

- (void)forgetDevice {
    _deviceID = kAudioObjectUnknown;
}

- (void)configureFormat:(AVAudioFormat *)format renderProc:(VibeOutputRenderProc)renderProc refCon:(void *)refCon {
    NSParameterAssert(!_running);
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved && format.channelCount > 0);
    _format = format;
    dispatch_async(_halQueue, ^{ [self halConfigureFormat:format renderProc:renderProc refCon:refCon]; });
}

- (void)start {
    if (_running) {
        return;
    }
    _running = YES;
    uint64_t generation = atomic_fetch_add_explicit(&_runGeneration, 1, memory_order_seq_cst) + 1;
    AudioDeviceID deviceID = _deviceID;
    dispatch_async(_halQueue, ^{ [self halStartForGeneration:generation device:deviceID]; });
}

- (void)stop {
    atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
    if (!_running) {
        return; // every start is already superseded, and the last stop is queued
    }
    atomic_fetch_add_explicit(&_runGeneration, 1, memory_order_seq_cst);
    _running = NO;
    dispatch_async(_halQueue, ^{ [self halStopUnit]; });
}

- (void)waitUntilIdle {
    dispatch_sync(_halQueue, ^{});
}

- (NSTimeInterval)presentationLatency {
    if (_deviceID == kAudioObjectUnknown) {
        return 0;
    }
    // The device's own reckoning of when a rendered sample is heard.
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(_deviceID, &rateAddress, 0, NULL, &size, &rate);
    AudioObjectPropertyAddress streamsAddress = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioStreamID stream = kAudioObjectUnknown;
    size = sizeof(stream);
    AudioObjectGetPropertyData(_deviceID, &streamsAddress, 0, NULL, &size, &stream);
    return VibeSecondsOfLatency(_deviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0, rate)
            + VibeSecondsOfLatency(_deviceID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0, rate)
            + (stream != kAudioObjectUnknown
               ? VibeSecondsOfLatency(_deviceID, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, stream, rate) : 0);
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

#pragma mark The unit's queue

- (void)halBindToDevice:(AudioDeviceID)deviceID {
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    // AUHAL takes a new device cleanly only across an initialize, and a bind
    // at the same rate is not followed by a reconfigure. Leaving a device
    // waits here for its IO to stop.
    if (_initialized) {
        AudioUnitUninitialize(_unit);
    }
    OSStatus status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &deviceID, sizeof(deviceID));
    if (_initialized && AudioUnitInitialize(_unit) != noErr) {
        _initialized = NO;
    }
    _bindStatus = status;
    double milliseconds = VibeMillisecondsSinceUptime(began);
    if (status != noErr) {
        LogError(@"AudioOutputUnit: bind to device %u refused (OSStatus %d) after %.1f ms", deviceID, (int)status, milliseconds);
        return;
    }
    [self halReadChannelMap];
    LogInfo(@"AudioOutputUnit: bind to device %u took %.1f ms", deviceID, milliseconds);
}

- (void)halConfigureFormat:(AVAudioFormat *)format renderProc:(VibeOutputRenderProc)renderProc refCon:(void *)refCon {
    AudioUnitUninitialize(_unit);
    _initialized = NO;
    AudioStreamBasicDescription description = *format.streamDescription;
    OSStatus status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &description, sizeof(description));
    if (status == noErr) {
        VibeOutputUnitStateInitialize(_state, format.channelCount, renderProc, refCon);
        status = AudioUnitInitialize(_unit);
    }
    _configureStatus = status;
    if (status != noErr) {
        LogError(@"AudioOutputUnit: %.0f Hz refused (OSStatus %d)", format.sampleRate, (int)status);
        return;
    }
    _initialized = YES;
    [self halReadChannelMap];
}

// The map the unit applies between its input and the device's stream, read
// where the unit is changed, so a reader never waits on this queue for it.
- (void)halReadChannelMap {
    AudioStreamBasicDescription output = {0};
    UInt32 size = sizeof(output);
    Boolean writable = false;
    NSMutableArray<NSNumber *> *map = nil;
    if (AudioUnitGetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &output, &size) == noErr
            && size == sizeof(output)
            && AudioUnitGetPropertyInfo(_unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, &size, &writable) == noErr
            && size > 0 && size == (uint64_t)output.mChannelsPerFrame * sizeof(SInt32)) {
        SInt32 *entries = malloc(size);
        UInt32 read = size;
        if (entries && AudioUnitGetProperty(_unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0,
                                            entries, &read) == noErr && read == size) {
            map = [NSMutableArray arrayWithCapacity:size / sizeof(SInt32)];
            for (UInt32 i = 0; i < size / sizeof(SInt32); i++) [map addObject:@(entries[i])];
        }
        free(entries);
    }
    self.channelMap = map;
}

- (void)halStartForGeneration:(uint64_t)generation device:(AudioDeviceID)deviceID {
    if (generation != atomic_load_explicit(&_runGeneration, memory_order_seq_cst)) {
        return; // a later start or stop owns the unit; this one never happened
    }
    OSStatus refusal = _bindStatus ?: _configureStatus;
    if (refusal == noErr) {
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        // TRAP: open, then re-check. A stop that landed between the check
        // above and this store must win, or the unit would pull the pipeline
        // after the player moved it to another device's rate. The stop bumps
        // the generation before it closes the gate, so one of the two sees
        // the other.
        atomic_store_explicit(&_state->gate, 1, memory_order_seq_cst);
        if (generation != atomic_load_explicit(&_runGeneration, memory_order_seq_cst)) {
            atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
            return;
        }
        refusal = [self halStartUnit];
        if (refusal == noErr) {
            double milliseconds = VibeMillisecondsSinceUptime(began);
            LogTiming(milliseconds > 100, @"AudioOutputUnit: start on device %u took %.1f ms", deviceID, milliseconds);
            return;
        }
        atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
    }
    BOOL bindRefused = _bindStatus != noErr;
    NSError *error = VibeOutputUnitError(refusal, bindRefused ? @"The output device refused the bind"
                                                             : @"Could not start the output unit");
    LogError(@"AudioOutputUnit: start refused: %@", error.localizedDescription);
    void (^handler)(NSError *, uint64_t, BOOL) = self.failureHandler;
    if (handler) handler(error, generation, bindRefused);
}

- (OSStatus)halStartUnit {
    return AudioOutputUnitStart(_unit);
}

// Also the dealloc's stop, which may run on this queue. Stopping a stopped
// unit is a no-op.
- (void)halStopUnit {
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    AudioOutputUnitStop(_unit);
    double milliseconds = VibeMillisecondsSinceUptime(began);
    LogTiming(milliseconds > 100, @"AudioOutputUnit: stop took %.1f ms", milliseconds);
    // The gate store and the callback's gate load are both seq_cst, so a
    // cycle that read the gate open has inRender set before this read sees
    // it clear; it finishes on its own within a buffer's time.
    for (int spin = 0; spin < kStopSpinLimit && atomic_load_explicit(&_state->inRender, memory_order_seq_cst); spin++) {
        usleep(kStopSpinMicroseconds);
    }
}

@end
