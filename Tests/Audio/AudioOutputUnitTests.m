//
//  AudioOutputUnitTests.m
//
//  The hosted output unit: its render callback, its counters, and its
//  configure, start, and stop on its own queue.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "AudioOutputUnitInternal.h"

#pragma mark - The hosted output unit's render callback

// The HAL's side of one IO cycle: one float buffer per channel, prefilled so
// silence is a write, not an absence.
static AudioBufferList *VibeTestIOBuffers(UInt32 channels, UInt32 frames, float fill) {
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer));
    list->mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        float *samples = malloc(frames * sizeof(float));
        for (UInt32 f = 0; f < frames; f++) {
            samples[f] = fill;
        }
        list->mBuffers[c].mNumberChannels = 1;
        list->mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        list->mBuffers[c].mData = samples;
    }
    return list;
}

static void VibeTestFreeIOBuffers(AudioBufferList *list) {
    for (UInt32 c = 0; c < list->mNumberBuffers; c++) {
        free(list->mBuffers[c].mData);
    }
    free(list);
}

// The engine's pattern: frame n of channel c is (n + 1)(c + 1), n counted
// across every call, so a slice that dropped or repeated a frame shows.
static float VibeTestPattern(uint64_t frame, UInt32 channel) {
    return (float)(frame + 1) * (float)(channel + 1);
}

// Samples of `data` that do not carry the pattern from `firstFrame` (silence,
// with `silence`) in the format's channels, or are not zero in any wider one.
static NSUInteger VibeTestMismatches(AudioBufferList *data, UInt32 channels, UInt32 frames, uint64_t firstFrame, BOOL silence) {
    NSUInteger mismatches = 0;
    for (UInt32 c = 0; c < data->mNumberBuffers; c++) {
        const float *samples = data->mBuffers[c].mData;
        for (UInt32 f = 0; f < frames; f++) {
            float expected = (silence || c >= channels) ? 0 : VibeTestPattern(firstFrame + f, c);
            mismatches += samples[f] != expected;
        }
    }
    return mismatches;
}

typedef struct {
    uint64_t rendered;   // frames the proc has produced
    NSUInteger calls;
    NSUInteger failures; // leading calls that fail
    UInt32 maxFrames;    // the largest cycle this proc accepts, as the pipeline's slicing bounds it
    OSStatus complaint;
} VibeTestEngine;

static OSStatus VibeTestRenderProc(void *refCon, const AudioTimeStamp *timestamp, UInt32 frameCount, AudioBufferList *buffer) {
    VibeTestEngine *engine = refCon;
    engine->calls++;
    if (engine->calls <= engine->failures) {
        return -3;
    }
    if (frameCount == 0 || frameCount > engine->maxFrames || buffer->mNumberBuffers < 2) {
        engine->complaint = -1;
        return -1;
    }
    // As the pipeline does: the first two buffers carry the signal, and a
    // wider device's further buffers are left silent.
    for (UInt32 c = 0; c < buffer->mNumberBuffers; c++) {
        if (buffer->mBuffers[c].mDataByteSize != frameCount * sizeof(float)) {
            engine->complaint = -2;
            return -2;
        }
        float *out = buffer->mBuffers[c].mData;
        for (UInt32 f = 0; f < frameCount; f++) {
            out[f] = c < 2 ? VibeTestPattern(engine->rendered + f, c) : 0;
        }
    }
    engine->rendered += frameCount;
    return noErr;
}

static OSStatus VibeTestCycle(VibeOutputUnitState *state, AudioBufferList *data, UInt32 frames,
                              AudioUnitRenderActionFlags *flags, UInt64 hostTime) {
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = (Float64)hostTime;
    stamp.mHostTime = hostTime;
    stamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    return VibeOutputUnitRender(state, flags, &stamp, 0, frames, data);
}

@interface AudioOutputUnitTests : XCTestCase
@end

@implementation AudioOutputUnitTests

- (void)testOutputUnitCallbackWritesSilenceWhileTheGateIsClosed {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    AudioBufferList *data = VibeTestIOBuffers(2, 512, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, 42), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(engine.calls, 0u);
    XCTAssertEqual(VibeTestMismatches(data, 2, 512, 0, YES), 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    XCTAssertEqual(atomic_load(&state.inRender), 0);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackHandsTheProcTheWholeCycle {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    uint64_t total = 0;
    UInt64 cycle = 0;
    for (NSNumber *pull in @[@63, @512, @4096, @8192, @63]) {
        UInt32 frames = pull.unsignedIntValue;
        AudioBufferList *data = VibeTestIOBuffers(2, frames, 0.5f);
        AudioUnitRenderActionFlags flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, frames, &flags, ++cycle), noErr);
        XCTAssertFalse(flags & kAudioUnitRenderAction_OutputIsSilence);
        XCTAssertEqual(VibeTestMismatches(data, 2, frames, total, NO), 0u, @"%u-frame pull", frames);
        total += frames;
        VibeTestFreeIOBuffers(data);
    }
    XCTAssertEqual(engine.complaint, noErr);
    XCTAssertEqual(engine.rendered, total);
    XCTAssertEqual(engine.calls, 5u); // one call per cycle, the 8192-frame one included
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
}

// The seam under clear_render_counters: nothing but the counters moves.
- (void)testOutputUnitCountersClearAndRestart {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    for (UInt64 cycle = 1; cycle <= 3; cycle++) {
        AudioBufferList *data = VibeTestIOBuffers(2, 256, 0.5f);
        AudioUnitRenderActionFlags flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, cycle), noErr);
        VibeTestFreeIOBuffers(data);
    }
    XCTAssertEqual(atomic_load(&state.cycles), 3ull);
    XCTAssertGreaterThan(atomic_load(&state.renderNanos), 0ull);
    XCTAssertGreaterThan(atomic_load(&state.renderMaxNanos), 0ull);
    atomic_store(&state.dropouts, 7);
    VibeOutputUnitStateClearCounters(&state);
    XCTAssertEqual(atomic_load(&state.cycles), 0ull);
    XCTAssertEqual(atomic_load(&state.renderNanos), 0ull);
    XCTAssertEqual(atomic_load(&state.renderMaxNanos), 0ull);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    XCTAssertEqual(atomic_load(&state.gate), 1);
    XCTAssertEqual(state.channels, 2u);
    AudioBufferList *data = VibeTestIOBuffers(2, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 4), noErr);
    VibeTestFreeIOBuffers(data);
    XCTAssertEqual(atomic_load(&state.cycles), 1ull);
    XCTAssertEqual(engine.calls, 4u);
}

- (void)testOutputUnitCallbackHandsTheProcEveryBuffer {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(4, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 1), noErr);
    XCTAssertEqual(VibeTestMismatches(data, 2, 256, 0, NO), 0u);
    XCTAssertEqual(engine.calls, 1u);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackWritesSilenceWhenTheHalOffersFewerBuffersThanTheFormat {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(1, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 1), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 1, 256, 0, YES), 0u);
    XCTAssertEqual(engine.calls, 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackWritesSilenceAndCountsADropoutWhenTheProcFails {
    VibeTestEngine engine = { .maxFrames = 8192, .failures = 2 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(2, 1024, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 1), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 2, 1024, 0, YES), 0u);
    XCTAssertEqual(engine.calls, 1u); // asked once: the proc never refuses, it renders or it fails
    XCTAssertEqual(atomic_load(&state.dropouts), 1ull);
    // The next cycle drops again, one dropout per cycle; the one after, with
    // the proc rendering, is exact and continues the count from zero frames.
    flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 2), noErr);
    XCTAssertEqual(atomic_load(&state.dropouts), 2ull);
    engine.failures = 0;
    flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 3), noErr);
    XCTAssertFalse(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 2, 1024, 0, NO), 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 2ull);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackCountsItsCostOnlyWhileTheGateIsOpen {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    AudioBufferList *data = VibeTestIOBuffers(2, 512, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    // A closed gate writes silence and is not a rendered cycle.
    XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, 1), noErr);
    XCTAssertEqual(atomic_load(&state.cycles), 0ull);
    XCTAssertEqual(atomic_load(&state.renderNanos), 0ull);
    atomic_store(&state.gate, 1);
    for (UInt64 cycle = 2; cycle <= 3; cycle++) {
        flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, cycle), noErr);
    }
    uint64_t nanos = atomic_load(&state.renderNanos), longest = atomic_load(&state.renderMaxNanos);
    XCTAssertEqual(atomic_load(&state.cycles), 2ull);
    XCTAssertGreaterThan(nanos, 0ull);
    XCTAssertGreaterThanOrEqual(longest * 2, nanos);
    XCTAssertLessThanOrEqual(longest, nanos);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitRefusesAFormatWithoutChannels {
    VibeOutputUnitState state = {0};
    XCTAssertFalse(VibeOutputUnitStateInitialize(&state, 0, NULL, NULL));
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, NULL, NULL));
}

// Runs `body` with the unit's HAL start replaced; the original is back after,
// whatever the body asserted.
static void VibeWithHALStart(OSStatus (^start)(void), void (^body)(void)) {
    Method method = class_getInstanceMethod(AudioOutputUnit.class, @selector(halStartUnit));
    IMP replacement = imp_implementationWithBlock(^OSStatus(id receiver) { return start(); });
    IMP original = method_setImplementation(method, replacement);
    @try {
        body();
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

static int32_t VibeGate(AudioOutputUnit *unit) {
    return atomic_load_explicit(&unit.state->gate, memory_order_seq_cst);
}

- (void)testAConfigurationFinishingAfterStopReplacementOrShutdownCannotStartObsoletePlayback {
    for (NSNumber *action in @[@0, @1, @2]) {
        AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
        dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
        NSMutableArray<NSNumber *> *configured = [NSMutableArray array];
        NSMutableArray<NSNumber *> *started = [NSMutableArray array];
        Method configure = class_getInstanceMethod(AudioOutputUnit.class, @selector(halConfigureFormat:renderProc:refCon:));
        IMP replacement = imp_implementationWithBlock(^(AudioOutputUnit *receiver, AVAudioFormat *format,
                                                        VibeOutputRenderProc proc, void *refCon) {
            if (configured.count == 0) {
                dispatch_semaphore_signal(entered);
                dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
            }
            [configured addObject:@(format.sampleRate)];
        });
        IMP original = method_setImplementation(configure, replacement);
        @try {
            VibeWithHALStart(^OSStatus {
                [started addObject:configured.lastObject];
                return noErr;
            }, ^{
                [unit configureFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2]
                           renderProc:VibeTestRenderProc refCon:NULL];
                [unit start];
                XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
                uint64_t oldStart = unit.runGeneration;
                if (action.intValue == 2) [unit markDead];
                else [unit stop];
                XCTAssertEqual(VibeGate(unit), 0);
                XCTAssertNotEqual(unit.runGeneration, oldStart);
                if (action.intValue == 1) {
                    [unit configureFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2]
                               renderProc:VibeTestRenderProc refCon:NULL];
                    [unit start];
                }
                dispatch_semaphore_signal(release);
                [unit waitUntilIdle];
                XCTAssertEqualObjects(started, action.intValue == 1 ? @[@48000] : @[], @"action %@", action);
                XCTAssertEqual(VibeGate(unit), action.intValue == 1 ? 1 : 0);
                [unit stop];
                [unit waitUntilIdle];
            });
        } @finally {
            dispatch_semaphore_signal(release);
            [unit waitUntilIdle];
            method_setImplementation(configure, original);
            imp_removeBlock(replacement);
        }
    }
}

// The device's IO thread is waited for on the unit's own queue, never the
// player's. A stop closes the gate at once, even mid-wait.
- (void)testAStartReturnsBeforeTheDeviceHasStartedAndAStopClosesTheGateAtOnce {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    XCTAssertNotNil(unit);
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    VibeWithHALStart(^OSStatus {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        return noErr;
    }, ^{
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [unit start];
        XCTAssertLessThan((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6, 20.0, @"the start waited for the device");
        XCTAssertTrue(unit.running);
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
        XCTAssertEqual(VibeGate(unit), 1, @"the gate opens before the device starts, so its first cycle renders");
        [unit stop];
        XCTAssertEqual(VibeGate(unit), 0, @"a stop closes the gate before it returns");
        XCTAssertFalse(unit.running);
        dispatch_semaphore_signal(release);
        [unit waitUntilIdle];
        XCTAssertEqual(VibeGate(unit), 0);
    });
}

// A unit still headed for the previous device or format must never pull the
// pipeline the player has already moved on.
- (void)testAStartSupersededBeforeItRunsNeverStartsTheDevice {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block int starts = 0;
    VibeWithHALStart(^OSStatus {
        if (++starts == 1) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return noErr;
    }, ^{
        [unit start];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
        [unit stop];
        [unit start]; // superseded by the stop below before the queue reaches it
        [unit stop];
        [unit start]; // the one that owns the unit
        dispatch_semaphore_signal(release);
        [unit waitUntilIdle];
        XCTAssertEqual(starts, 2, @"the superseded start reached the device");
        XCTAssertEqual(VibeGate(unit), 1);
        XCTAssertTrue(unit.running);
        [unit stop];
        [unit waitUntilIdle];
        XCTAssertEqual(VibeGate(unit), 0);
    });
}

// A refusal arrives later, through the handler, with the generation of the
// start it refused; a stop after it makes that generation stale, which is how
// the player tells a refusal it must act on from a moot one.
- (void)testARefusedStartReportsItsGenerationAndLeavesTheGateClosed {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    __block NSError *reported = nil;
    __block uint64_t reportedGeneration = 0;
    __block BOOL reportedBind = YES;
    unit.failureHandler = ^(NSError *error, uint64_t runGeneration, BOOL bindRefused) {
        reported = error;
        reportedGeneration = runGeneration;
        reportedBind = bindRefused;
    };
    VibeWithHALStart(^OSStatus { return kAudioHardwareNotRunningError; }, ^{
        [unit start];
        [unit waitUntilIdle];
        XCTAssertNotNil(reported);
        XCTAssertEqual(reported.code, kAudioHardwareNotRunningError);
        XCTAssertFalse(reportedBind);
        XCTAssertEqual(reportedGeneration, unit.runGeneration, @"nothing superseded this start");
        XCTAssertEqual(VibeGate(unit), 0);
        [unit stop];
        XCTAssertNotEqual(reportedGeneration, unit.runGeneration, @"a stop makes the refusal moot");
    });
}

// The bind reads nothing on the caller's queue: a device the HAL refuses
// fails the next start, as a bind refusal.
- (void)testABindToADeviceTheHALDoesNotKnowFailsTheNextStart {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    __block NSError *reported = nil;
    __block BOOL reportedBind = NO;
    unit.failureHandler = ^(NSError *error, uint64_t runGeneration, BOOL bindRefused) {
        reported = error;
        reportedBind = bindRefused;
    };
    [unit bindToDevice:(AudioDeviceID)0x7FFFFFF0];
    XCTAssertEqual(unit.deviceID, (AudioDeviceID)0x7FFFFFF0, @"the bind is recorded at once");
    [unit start];
    [unit waitUntilIdle];
    XCTAssertNotNil(reported);
    XCTAssertTrue(reportedBind);
    XCTAssertEqual(VibeGate(unit), 0);
    [unit stop];
}

- (void)testOutputUnitIsUnboundAtInitAndStopsSafelyBeforeAnyStart {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    XCTAssertNotNil(unit);
    XCTAssertEqual(unit.deviceID, kAudioObjectUnknown);
    XCTAssertNil(unit.format);
    XCTAssertFalse(unit.running);
    XCTAssertEqual(unit.dropouts, 0ull);
    XCTAssertEqual(unit.renderCycles, 0ull);
    XCTAssertEqual(unit.renderMeanMicroseconds, 0.0);
    XCTAssertEqual(unit.renderMaxMicroseconds, 0.0);
    [unit stop];
    XCTAssertFalse(unit.running);
}

// The media-services reset: a start queued before it never reaches the dead
// instance, and the unit's end disposes it without a stop.
- (void)testADeadUnitIsNeverStartedAgain {
    __block AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block int starts = 0;
    VibeWithHALStart(^OSStatus {
        if (++starts == 1) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return noErr;
    }, ^{
        [unit start];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
        [unit stop];
        [unit start]; // queued behind the device's slow start when the reset lands
        [unit markDead];
        XCTAssertEqual(VibeGate(unit), 0);
        XCTAssertFalse(unit.running);
        dispatch_semaphore_signal(release);
        [unit waitUntilIdle];
        XCTAssertEqual(starts, 1, @"a start reached the dead instance");
        XCTAssertEqual(VibeGate(unit), 0);
        unit = nil;
    });
}

@end
