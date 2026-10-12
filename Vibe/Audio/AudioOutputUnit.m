//
//  AudioOutputUnit.m
//  Vibe
//

#import "AudioOutputUnitInternal.h"
#if !TARGET_OS_OSX
#import <os/lock.h>
#endif
#include <unistd.h>

// Every unit's run generations, so that one names a single start or stop of
// a single unit: a unit made after an iOS media-services reset never repeats
// a generation its predecessor's late refusal carries.
static _Atomic uint64_t VibeOutputUnitGenerations;

static uint64_t VibeOutputUnitNextGeneration(void) {
    return atomic_fetch_add_explicit(&VibeOutputUnitGenerations, 1, memory_order_seq_cst) + 1;
}

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

// Everything the IO thread does; the checked region makes a blocking call,
// the proc's included, a build error.
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

// Timed outside the checked function: the clock read is not on the checker's
// list, though it is a commpage read that blocks on nothing.
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
        if (state->sampleRate > 0 && nanos * state->sampleRate > frameCount * 1e9) {
            atomic_fetch_add_explicit(&state->lateCycles, 1, memory_order_relaxed);
        }
        if (timestamp && (timestamp->mFlags & kAudioTimeStampSampleTimeValid)) {
            if (!atomic_exchange_explicit(&state->clockRestart, 0, memory_order_acquire)
                    && timestamp->mSampleTime != state->nextSampleTime) {
                atomic_fetch_add_explicit(&state->clockJumps, 1, memory_order_relaxed);
                if (timestamp->mSampleTime > state->nextSampleTime) {
                    atomic_fetch_add_explicit(&state->skippedFrames,
                                              (uint64_t)(timestamp->mSampleTime - state->nextSampleTime),
                                              memory_order_relaxed);
                }
            }
            state->nextSampleTime = timestamp->mSampleTime + frameCount;
        }
    }
    return status;
}

void VibeOutputUnitStateClearCounters(VibeOutputUnitState *state) {
    atomic_store_explicit(&state->dropouts, 0, memory_order_relaxed);
    atomic_store_explicit(&state->cycles, 0, memory_order_relaxed);
    atomic_store_explicit(&state->renderNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&state->renderMaxNanos, 0, memory_order_relaxed);
    atomic_store_explicit(&state->lateCycles, 0, memory_order_relaxed);
    atomic_store_explicit(&state->clockJumps, 0, memory_order_relaxed);
    atomic_store_explicit(&state->skippedFrames, 0, memory_order_relaxed);
}

#pragma mark - The unit

static OSStatus VibeCreateOutputUnit(VibeOutputUnitState *state, AudioUnit *unit) {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
#if TARGET_OS_OSX
        .componentSubType = kAudioUnitSubType_HALOutput,
#else
        .componentSubType = kAudioUnitSubType_RemoteIO,
#endif
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component) return kAudioUnitErr_FailedInitialization;
    OSStatus status = AudioComponentInstanceNew(component, unit);
    UInt32 on = 1, off = 0;
    if (status == noErr) {
        status = AudioUnitSetProperty(*unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, sizeof(on));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(*unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, sizeof(off));
    }
    if (status == noErr) {
        AURenderCallbackStruct callback = { .inputProc = VibeOutputUnitRender, .inputProcRefCon = state };
        status = AudioUnitSetProperty(*unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (status != noErr && *unit) {
        AudioComponentInstanceDispose(*unit);
        *unit = NULL;
    }
    return status;
}

@interface AudioOutputUnit ()
@property (atomic, copy, readwrite, nullable) NSArray<NSNumber *> *channelMap;
#if TARGET_OS_OSX
@property (atomic, readwrite) NSTimeInterval presentationLatency;
@property (atomic, readwrite) NSTimeInterval bufferLatency;
#endif
#if !TARGET_OS_OSX
- (void)reportSystemStop;
#endif
@end

#if !TARGET_OS_OSX
// TRAP: RemoteIO reports IsRunning on a thread of its own, and removing the
// listener does not wait for a report in flight, so the listener's refCon is
// a token, never the unit: a unit already deallocating is not found.
static os_unfair_lock VibeRunningListenersLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSNumber *, AudioOutputUnit *> *VibeRunningListeners; // weak values
static _Atomic uintptr_t VibeRunningListenerTokens;
#endif

@implementation AudioOutputUnit {
    AudioUnit _unit;
    VibeOutputUnitState *_state;
    dispatch_queue_t _halQueue;
    // Player-queue confined: the state the queued HAL work is headed for.
#if TARGET_OS_OSX
    AudioDeviceID _deviceID;
#endif
    AVAudioFormat *_format;
    BOOL _running;
    _Atomic uint64_t _runGeneration;
    _Atomic uint64_t _startedGeneration; // the HAL queue's, read by the iOS system-stop report
    // HAL-queue confined.
    BOOL _initialized;
    OSStatus _bindStatus;       // the last bind's refusal, until a bind lands; macOS only
#if TARGET_OS_OSX
    AudioDeviceID _boundDeviceID; // the device the last landed bind set
#endif
    OSStatus _configureStatus;  // the last configure's refusal, until one lands
    _Atomic bool _dead;         // markDead: nothing messages the instance again
#if !TARGET_OS_OSX
    uintptr_t _runningListenerToken;
#endif
}

#if !TARGET_OS_OSX
static void VibeOutputUnitRunningChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property,
                                         AudioUnitScope scope, AudioUnitElement element) {
    void *held = NULL;
    dispatch_queue_t queue = nil;
    @autoreleasepool {
        os_unfair_lock_lock(&VibeRunningListenersLock);
        AudioOutputUnit *outputUnit = [VibeRunningListeners objectForKey:@((uintptr_t)refCon)];
        os_unfair_lock_unlock(&VibeRunningListenersLock);
        [outputUnit reportSystemStop];
        if (outputUnit) {
            queue = outputUnit->_halQueue;
            held = (__bridge_retained void *)outputUnit;
        }
    }
    // TRAP: the reference taken here is dropped on the unit's queue: were it
    // the last, a dealloc inside RemoteIO's own callback would dispose the
    // instance calling it.
    if (held) {
        dispatch_async_f(queue, held, (dispatch_function_t)CFRelease);
    }
}
#endif

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _state = calloc(1, sizeof(VibeOutputUnitState));
    if (!_state || VibeCreateOutputUnit(_state, &_unit) != noErr || !_unit) {
        return nil;
    }
#if TARGET_OS_OSX
    _deviceID = kAudioObjectUnknown;
#endif
    // Default QoS, as the player queue: the waits here are for a device's IO
    // thread, and the player queue is the only thing that ever waits on this.
    _halQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.outputUnit", DISPATCH_QUEUE_SERIAL);
#if !TARGET_OS_OSX
    _runningListenerToken = atomic_fetch_add_explicit(&VibeRunningListenerTokens, 1, memory_order_relaxed) + 1;
    os_unfair_lock_lock(&VibeRunningListenersLock);
    if (!VibeRunningListeners) VibeRunningListeners = [NSMapTable strongToWeakObjectsMapTable];
    [VibeRunningListeners setObject:self forKey:@(_runningListenerToken)];
    os_unfair_lock_unlock(&VibeRunningListenersLock);
    AudioUnitAddPropertyListener(_unit, kAudioOutputUnitProperty_IsRunning, VibeOutputUnitRunningChanged,
                                 (void *)_runningListenerToken);
#endif
    return self;
}

// Every queued block retains the unit, so none is pending here, and this may
// run on the unit's own queue: it must not wait on it.
- (void)dealloc {
    if (_unit) {
        BOOL dead = atomic_load_explicit(&_dead, memory_order_seq_cst);
        atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
#if !TARGET_OS_OSX
        os_unfair_lock_lock(&VibeRunningListenersLock);
        [VibeRunningListeners removeObjectForKey:@(_runningListenerToken)];
        os_unfair_lock_unlock(&VibeRunningListenersLock);
        if (!dead) {
            AudioUnitRemovePropertyListenerWithUserData(_unit, kAudioOutputUnitProperty_IsRunning,
                                                        VibeOutputUnitRunningChanged, (void *)_runningListenerToken);
        }
#endif
        [self halStopUnit];
        if (!dead) {
            AudioUnitUninitialize(_unit);
        }
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

- (uint64_t)lateCycles {
    return atomic_load_explicit(&_state->lateCycles, memory_order_relaxed);
}

- (uint64_t)clockJumps {
    return atomic_load_explicit(&_state->clockJumps, memory_order_relaxed);
}

- (uint64_t)skippedFrames {
    return atomic_load_explicit(&_state->skippedFrames, memory_order_relaxed);
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

#if TARGET_OS_OSX
static double VibeSecondsOfLatency(AudioDeviceID device, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope,
                                   AudioObjectID object, double rate) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 frames = 0, size = sizeof(frames);
    if (AudioObjectGetPropertyData(object ?: device, &address, 0, NULL, &size, &frames) != noErr || rate <= 0) {
        return 0;
    }
    return frames / rate;
}
#endif

static NSError *VibeOutputUnitError(OSStatus status, NSString *what) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (OSStatus %d)", what, (int)status]}];
}

static double VibeMillisecondsSinceUptime(uint64_t began) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6;
}

#pragma mark Player-queue API

#if TARGET_OS_OSX
- (void)bindToDevice:(AudioDeviceID)deviceID {
    NSParameterAssert(!_running);
    _deviceID = deviceID;
    dispatch_async(_halQueue, ^{ [self halBindToDevice:deviceID]; });
}

- (void)forgetDevice {
    _deviceID = kAudioObjectUnknown;
    dispatch_async(_halQueue, ^{
        self->_boundDeviceID = kAudioObjectUnknown;
        [self halReadLatencies];
    });
}
#endif

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
    uint64_t generation = VibeOutputUnitNextGeneration();
    atomic_store_explicit(&_runGeneration, generation, memory_order_seq_cst);
#if TARGET_OS_OSX
    AudioDeviceID deviceID = _deviceID;
#else
    UInt32 deviceID = 0; // the route is the session's
#endif
    dispatch_async(_halQueue, ^{ [self halStartForGeneration:generation device:deviceID]; });
}

- (void)stop {
    // Not running: every start is already superseded, and the last stop is queued.
    BOOL wasRunning = _running;
    if (wasRunning) {
        atomic_store_explicit(&_runGeneration, VibeOutputUnitNextGeneration(), memory_order_seq_cst);
        _running = NO;
    }
    // TRAP: after the bump, as halStartForGeneration requires. Closed first,
    // a start could re-check the old generation after it and leave the gate
    // open under a stopped unit.
    atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
    if (wasRunning) {
        dispatch_async(_halQueue, ^{ [self halStopUnit]; });
    }
}

- (void)markDead {
    atomic_store_explicit(&_dead, true, memory_order_seq_cst);
    [self stop];
}

- (void)waitUntilIdle {
    dispatch_sync(_halQueue, ^{});
}

#if !TARGET_OS_OSX
- (NSTimeInterval)presentationLatency {
    return AVAudioSession.sharedInstance.outputLatency;
}

- (NSTimeInterval)bufferLatency {
    return AVAudioSession.sharedInstance.IOBufferDuration;
}
#endif

#pragma mark The unit's queue

#if TARGET_OS_OSX
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
    _boundDeviceID = status == noErr ? deviceID : kAudioObjectUnknown;
    [self halReadLatencies];
    double milliseconds = VibeMillisecondsSinceUptime(began);
    if (status != noErr) {
        LogError(@"AudioOutputUnit: bind to device %u refused (OSStatus %d) after %.1f ms", deviceID, (int)status, milliseconds);
        return;
    }
    [self halReadChannelMap];
    LogInfo(@"AudioOutputUnit: bind to device %u took %.1f ms", deviceID, milliseconds);
}

- (void)halReadLatencies {
    AudioDeviceID device = _boundDeviceID;
    if (device == kAudioObjectUnknown) {
        self.presentationLatency = 0;
        self.bufferLatency = 0;
        return;
    }
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(device, &rateAddress, 0, NULL, &size, &rate);
    AudioObjectPropertyAddress streamsAddress = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioStreamID stream = kAudioObjectUnknown;
    size = sizeof(stream);
    AudioObjectGetPropertyData(device, &streamsAddress, 0, NULL, &size, &stream);
    self.presentationLatency = VibeSecondsOfLatency(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0, rate)
            + VibeSecondsOfLatency(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0, rate)
            + (stream != kAudioObjectUnknown
               ? VibeSecondsOfLatency(device, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, stream, rate) : 0);
    self.bufferLatency = VibeSecondsOfLatency(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, 0, rate);
}
#endif

- (void)halConfigureFormat:(AVAudioFormat *)format renderProc:(VibeOutputRenderProc)renderProc refCon:(void *)refCon {
    if (atomic_load_explicit(&_dead, memory_order_seq_cst)) {
        return;
    }
    AudioUnitUninitialize(_unit);
    _initialized = NO;
    OSStatus status = noErr;
#if TARGET_OS_OSX
    // TRAP: AUHAL can reinitialize before its device-format notification and
    // keep the old converter. A fresh component binds the current format.
    AudioUnit replacement = NULL;
    status = VibeCreateOutputUnit(_state, &replacement);
    // No landed bind leaves the fresh unit on the system default, as the first
    // one was; written, device 0 initializes and starts but never renders.
    if (status == noErr && _boundDeviceID != kAudioObjectUnknown) {
        status = AudioUnitSetProperty(replacement, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &_boundDeviceID, sizeof(_boundDeviceID));
    }
    if (status == noErr) {
        AudioComponentInstanceDispose(_unit);
        _unit = replacement;
    } else if (replacement) {
        AudioComponentInstanceDispose(replacement);
    }
#endif
    AudioStreamBasicDescription description = *format.streamDescription;
    if (status == noErr) {
        status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      &description, sizeof(description));
    }
    if (status == noErr) {
        VibeOutputUnitStateInitialize(_state, format.channelCount, renderProc, refCon);
        _state->sampleRate = format.sampleRate;
        status = AudioUnitInitialize(_unit);
    }
    _configureStatus = status;
    if (status != noErr) {
        LogError(@"AudioOutputUnit: %.0f Hz refused (OSStatus %d)", format.sampleRate, (int)status);
        return;
    }
    _initialized = YES;
    [self halReadChannelMap];
#if TARGET_OS_OSX
    [self halReadLatencies];
#endif
}

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

- (void)halStartForGeneration:(uint64_t)generation device:(UInt32)deviceID {
    if (generation != atomic_load_explicit(&_runGeneration, memory_order_seq_cst)) {
        return; // a later start or stop owns the unit; this one never happened
    }
    OSStatus refusal = _bindStatus ?: _configureStatus;
    if (refusal == noErr) {
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        // TRAP: open, then re-check. A stop landing between the check above
        // and this store must win, or the unit pulls the pipeline at a rate
        // the player has moved off. The stop bumps the generation before it
        // closes the gate, so one of the two sees the other.
        atomic_store_explicit(&_state->clockRestart, 1, memory_order_release);
        atomic_store_explicit(&_state->gate, 1, memory_order_seq_cst);
        if (generation != atomic_load_explicit(&_runGeneration, memory_order_seq_cst)) {
            atomic_store_explicit(&_state->gate, 0, memory_order_seq_cst);
            return;
        }
        refusal = [self halStartUnit];
        if (refusal == noErr) {
            atomic_store_explicit(&_startedGeneration, generation, memory_order_release);
            double milliseconds = VibeMillisecondsSinceUptime(began);
            LogTiming(milliseconds > 100, @"AudioOutputUnit: start on device %u took %.1f ms", deviceID, milliseconds);
#if TARGET_OS_OSX
            [self halReadLatencies]; // a started device may have resized its buffer
#endif
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

#if !TARGET_OS_OSX
// iOS stops RemoteIO under the app when an interruption takes the session,
// and says so only through IsRunning. The player's own stops close the gate
// before the unit stops, so a stop seen with the gate open is the system's.
- (void)reportSystemStop {
    UInt32 running = 1, size = sizeof(running);
    if (!atomic_load_explicit(&_state->gate, memory_order_seq_cst)
            || AudioUnitGetProperty(_unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) != noErr
            || running) {
        return;
    }
    LogWarn(@"AudioOutputUnit: the system stopped the unit");
    // The generation the unit last started under, never the current one: our
    // own stop's callback can land after the next start has opened the gate
    // and before its unit runs, and must not fail that start.
    void (^handler)(NSError *, uint64_t, BOOL) = self.failureHandler;
    if (handler) handler(nil, atomic_load_explicit(&_startedGeneration, memory_order_acquire), NO);
}
#endif

- (OSStatus)halStartUnit {
    return AudioOutputUnitStart(_unit);
}

// Also the dealloc's stop, which may run on this queue. Stopping a stopped
// unit is a no-op; a dead one is not messaged, but its callback is still
// waited out, since the state it reads is freed with the unit.
- (void)halStopUnit {
    if (!atomic_load_explicit(&_dead, memory_order_seq_cst)) {
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        AudioOutputUnitStop(_unit);
        double milliseconds = VibeMillisecondsSinceUptime(began);
        LogTiming(milliseconds > 100, @"AudioOutputUnit: stop took %.1f ms", milliseconds);
    }
    // The gate store and the callback's gate load are both seq_cst, so a
    // cycle that read the gate open has inRender set before this read sees
    // it clear; it finishes on its own within a buffer's time.
    for (int spin = 0; spin < kStopSpinLimit && atomic_load_explicit(&_state->inRender, memory_order_seq_cst); spin++) {
        usleep(kStopSpinMicroseconds);
    }
}

@end
