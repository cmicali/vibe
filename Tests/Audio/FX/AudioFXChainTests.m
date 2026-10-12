//
//  AudioFXChainTests.m
//  VibeTests
//
//  The FX chain hosted on its own and rendered over the debug pump's
//  frame-driven clock, the one the render suite drives the whole player on.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioFX.h"
#import "AudioFixtures.h"
#import "AudioFX+Debug.h"
#import "VibeManualRenderPump.h"

static const double kRate = 48000;
static const UInt32 kBlock = 512;
static const UInt32 kMaxFrames = 4096;

typedef float (^VibeTestSource)(uint64_t frame, int channel);

// A deterministic, non-periodic signal, so an exact comparison means something.
static float VibeTestNoise(uint64_t frame, int channel) {
    uint32_t x = (uint32_t)frame * 2654435761u + (uint32_t)channel * 40503u;
    x ^= x >> 13;
    x *= 0x5bd1e995u;
    x ^= x >> 15;
    return (float)(int32_t)x / (float)INT32_MAX * 0.25f;
}

static double VibeTestRMS(NSData *capture, int channel, NSUInteger from, NSUInteger count) {
    const float *p = capture.bytes;
    NSUInteger frames = capture.length / sizeof(float) / 2;
    double sum = 0;
    NSUInteger n = 0;
    for (NSUInteger f = from; f < from + count && f < frames; f++, n++) {
        double v = p[f * 2 + channel];
        sum += v * v;
    }
    return n ? sqrt(sum / n) : 0;
}

@interface AudioFXChainTests : XCTestCase
@end

@implementation AudioFXChainTests {
    dispatch_queue_t _queue;
    AudioFX *_fx;
    VibeManualRenderPump *_pump;
    VibeTestSource _source; // what the render fills its input from; nil is silence
    NSMutableArray<dispatch_block_t> *_renderLeaveWork;
}

- (void)setUp {
    [super setUp];
    _queue = dispatch_queue_create("com.vibe.test.fx-chain", DISPATCH_QUEUE_SERIAL);
    __weak AudioFXChainTests *weakSelf = self;
    // The scheduler is the pump's virtual clock, as the player's is under the
    // pump; the chain renders on the test thread, so no render is left to wait out.
    _fx = [[AudioFX alloc] initWithQueue:_queue scheduler:^(NSTimeInterval seconds, dispatch_block_t block) {
        AudioFXChainTests *strongSelf = weakSelf;
        [strongSelf->_pump scheduleAfter:seconds block:block];
    } afterRenderLeaves:^(dispatch_block_t work) {
        AudioFXChainTests *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_renderLeaveWork) [strongSelf->_renderLeaveWork addObject:[work copy]];
        else work();
    }];
    [self attachPumpAt:kRate];
}

- (void)tearDown {
    AudioFX *fx = _fx;
    VibeManualRenderPump *pump = _pump;
    dispatch_sync(_queue, ^{
        [fx setConnected:NO format:nil maximumFrameCount:kMaxFrames];
        [pump cancel];
    });
    _fx = nil;
    [super tearDown];
}

- (AVAudioFormat *)formatAt:(double)rate {
    return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
}

- (void)onQueue:(dispatch_block_t)block {
    dispatch_sync(_queue, block);
}

// A frame-driven pump at `rate` whose render fills the chunk from the source
// and runs the chain over it, stamped on the pump's timeline.
- (void)attachPumpAt:(double)rate {
    _pump = [[VibeManualRenderPump alloc] initWithFormat:[self formatAt:rate] automatic:NO];
    __weak AudioFXChainTests *weakSelf = self;
    [_pump attachRender:^OSStatus(AVAudioPCMBuffer *chunk, AVAudioFrameCount count) {
        AudioFXChainTests *strongSelf = weakSelf;
        uint64_t first = strongSelf->_pump.renderedFrames;
        VibeTestSource source = strongSelf->_source;
        for (int c = 0; c < 2; c++) {
            for (UInt32 f = 0; f < count; f++) {
                chunk.floatChannelData[c][f] = source ? source(first + f, c) : 0;
            }
        }
        chunk.frameLength = count;
        AudioTimeStamp stamp = {0};
        stamp.mSampleTime = (Float64)first;
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        return VibeFXChainRender(strongSelf->_fx.chain, &stamp, count, chunk.mutableAudioBufferList);
    } running:^BOOL{ return YES; } queue:_queue];
}

- (void)connectAt:(double)rate {
    AVAudioFormat *format = [self formatAt:rate];
    [self onQueue:^{ [self->_fx setConnected:YES format:format maximumFrameCount:kMaxFrames]; }];
    XCTAssertTrue(_fx.connected);
    XCTAssertEqual(_fx.hostedUnitCount, 10u);
}

// Renders `frames` of `source` through the chain in blocks on the queue, the
// pump running the scheduled steps at their exact frames; the output,
// interleaved, lands in `capture` when given.
- (void)render:(NSUInteger)frames source:(VibeTestSource)source into:(NSMutableData *)capture {
    _source = source;
    while (frames) {
        AVAudioFrameCount count = (AVAudioFrameCount)MIN(frames, (NSUInteger)kBlock);
        __block AVAudioPCMBuffer *buffer = nil;
        __block NSError *error = nil;
        [self onQueue:^{ buffer = [self->_pump renderFrames:count error:&error]; }];
        XCTAssertNotNil(buffer, @"%@", error);
        if (capture && buffer) {
            VibeAppendPCM(capture, buffer);
        }
        frames -= count;
    }
}

- (void)assertCapture:(NSData *)capture isNoiseFrom:(uint64_t)firstFrame {
    const float *out = capture.bytes;
    NSUInteger frames = capture.length / sizeof(float) / 2;
    NSUInteger mismatches = 0;
    for (NSUInteger f = 0; f < frames; f++) {
        for (int c = 0; c < 2; c++) {
            if (out[f * 2 + c] != VibeTestNoise(firstFrame + f, c)) {
                mismatches++;
            }
        }
    }
    XCTAssertEqual(mismatches, 0u, @"%lu of %lu samples changed", (unsigned long)mismatches, (unsigned long)frames * 2);
}

// Units 0 and 1: the EQ on the dry path, and the reverb, whose stale scratch
// would otherwise be summed into the audio with the failure unreported.
- (void)testAFailedUnitRenderReturnsItsStatus {
    for (NSNumber *unit in @[@0, @1]) {
        [self connectAt:kRate];
        BOOL lowKill = unit.intValue == 0;
        [self onQueue:^{
            if (lowKill) self->_fx.lowKillEnabled = YES;
            else self->_fx.reverbSendEnabled = YES;
        }];
        [self render:kBlock * 4 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:nil];
        __block BOOL uninitialized = NO;
        [self onQueue:^{ uninitialized = [self->_fx debugUninitializeUnitAtIndex:unit.unsignedIntegerValue]; }];
        XCTAssertTrue(uninitialized);
        __block AVAudioPCMBuffer *buffer = nil;
        __block NSError *error = nil;
        [self onQueue:^{ buffer = [self->_pump renderFrames:kBlock error:&error]; }];
        XCTAssertNil(buffer, @"unit %@: a failed render was reported as a rendered slice", unit);
        XCTAssertNotNil(error, @"unit %@", unit);
        [self onQueue:^{
            self->_fx.lowKillEnabled = NO;
            self->_fx.reverbSendEnabled = NO;
            [self->_fx setConnected:NO format:nil maximumFrameCount:kMaxFrames];
        }];
    }
}

- (void)testAnIdleChainRendersNoUnitAndPassesTheSignalExactly {
    [self connectAt:kRate];
    NSMutableData *capture = [NSMutableData data];
    uint64_t first = _pump.renderedFrames;
    [self render:48000 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:capture];
    [self assertCapture:capture isNoiseFrom:first];
    XCTAssertEqual(_fx.unitRenders, 0ull, @"an idle chain rendered a unit");
}

- (void)testAHeldDelaySendEchoesAtItsTapAndRestsAfterItsTail {
    [self connectAt:kRate];
    _fx.delayTapBPM = 120;
    _fx.delaySendEnabled = YES;
    [self onQueue:^{}];
    // The gate opens over 10 ms of steps and slews over 25 ms: let it settle.
    [self render:4800 source:nil into:nil];
    XCTAssertGreaterThan(_fx.unitRenders, 0ull, @"a held send renders its units");
    NSMutableData *capture = [NSMutableData data];
    uint64_t impulse = _pump.renderedFrames;
    [self render:48000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:capture];
    // At 120 BPM the 1/8-note tap is 0.25 s: the first echo lands left, the
    // second right, and the trail decays.
    NSUInteger tap = 12000;
    double left = VibeTestRMS(capture, 0, tap - 64, 256);
    double right = VibeTestRMS(capture, 1, tap - 64, 256);
    XCTAssertGreaterThan(left, right * 1.9);
    XCTAssertGreaterThan(left, 0.00001);
    XCTAssertGreaterThan(VibeTestRMS(capture, 1, 2 * tap - 64, 256), VibeTestRMS(capture, 0, 2 * tap - 64, 256) * 1.9);
    XCTAssertLessThan(VibeTestRMS(capture, 0, 5 * tap - 64, 256), left);
    const float *out = capture.bytes;
    XCTAssertEqual(out[0], 0.5f, @"the dry path is untouched");
    // Released, the stage rings out for its tail, then rests: no unit renders.
    _fx.delaySendEnabled = NO;
    [self onQueue:^{}];
    [self render:(NSUInteger)(kRate * 40) source:nil into:nil];
    uint64_t rested = _fx.unitRenders;
    NSMutableData *silence = [NSMutableData data];
    [self render:48000 source:nil into:silence];
    XCTAssertEqual(_fx.unitRenders, rested, @"a rested stage rendered");
    XCTAssertEqual(VibeTestRMS(silence, 0, 0, 48000), 0.0);
    XCTAssertEqual(VibeTestRMS(silence, 1, 0, 48000), 0.0);
}

// With both delay sends held, the impulse response is the dry impulse plus
// each send's return on its own: a return mixed in before a later send's gate
// would be echoed by it. The delays are deterministic, so the captures compare
// to float rounding.
- (void)testSendsTapTheDrySignalIndependently {
    NSMutableData *captures[3];
    for (int phase = 0; phase < 3; phase++) {
        [self connectAt:kRate];
        _fx.delayTapBPM = 120;
        if (phase != 1) _fx.delaySendEnabled = YES;
        if (phase != 0) _fx.shortDelaySendEnabled = YES;
        [self onQueue:^{}];
        [self render:4800 source:nil into:nil];
        uint64_t impulse = _pump.renderedFrames;
        captures[phase] = [NSMutableData data];
        [self render:48000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:captures[phase]];
        // Back to silence and a reset chain, so each phase starts from the same state.
        _fx.delaySendEnabled = NO;
        _fx.shortDelaySendEnabled = NO;
        [self onQueue:^{ [self->_fx setConnected:NO format:nil maximumFrameCount:kMaxFrames]; }];
    }
    const float *eighth = captures[0].bytes, *sixteenth = captures[1].bytes, *both = captures[2].bytes;
    NSUInteger samples = captures[2].length / sizeof(float);
    XCTAssertEqual(captures[0].length, captures[2].length);
    XCTAssertEqual(captures[1].length, captures[2].length);
    float worst = 0;
    for (NSUInteger i = 0; i < samples; i++) {
        float dry = i < 2 ? 0.5f : 0.0f; // the impulse, in both channels of frame 0
        worst = MAX(worst, fabsf(both[i] - (eighth[i] + sixteenth[i] - dry)));
    }
    XCTAssertLessThan(worst, 1e-4f, @"a send echoed another's return, or a return was counted twice");
    // The 1/8-note echo (one sample of about 0.13, so 0.008 RMS over the
    // window) is loud enough that its re-echo a sixteenth later would show
    // fifty times over the tolerance above.
    XCTAssertGreaterThan(VibeTestRMS(captures[0], 0, 12000 - 64, 256), 0.005, @"the 1/8-note send's first echo");
}

// Every stage is at rest, so even a render still pointed at the chain renders
// no unit and changes no sample, and the tails' pending rests fire without
// touching a unit. (The player also withdraws the pointer.)
- (void)testADisconnectedChainWithRingingTailsRendersNothing {
    [self connectAt:kRate];
    _fx.delayTapBPM = 120;
    _fx.reverbSendEnabled = YES;
    _fx.delaySendEnabled = YES;
    [self onQueue:^{}];
    [self render:4800 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:nil];
    _fx.reverbSendEnabled = NO;
    _fx.delaySendEnabled = NO;
    [self onQueue:^{}];
    [self render:2400 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:nil];
    XCTAssertGreaterThan(_fx.unitRenders, 0ull);
    [self onQueue:^{ [self->_fx setConnected:NO format:nil maximumFrameCount:kMaxFrames]; }];
    XCTAssertFalse(_fx.connected);
    uint64_t rested = _fx.unitRenders;
    NSMutableData *capture = [NSMutableData data];
    uint64_t first = _pump.renderedFrames;
    [self render:48000 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:capture];
    [self assertCapture:capture isNoiseFrom:first];
    XCTAssertEqual(_fx.unitRenders, rested, @"a disconnected chain rendered a unit");
    [self render:(NSUInteger)(kRate * 12) source:nil into:nil];
    XCTAssertEqual(_fx.unitRenders, rested, @"a pending rest rendered a unit");
    _fx.delayTapBPM = 128;
    [self onQueue:^{}];
    XCTAssertEqual(_fx.unitRenders, rested);
}

// With the reverb and the 1/8-note delay held, the impulse response is the dry
// impulse plus each return on its own, through the release too. The reverb's
// two hostings differ by float rounding, so the tolerance sits well above that
// and well below an echo.
- (void)testCombinedReturnsSumWithOverlappingTails {
    NSMutableData *captures[3];
    for (int phase = 0; phase < 3; phase++) {
        [self connectAt:kRate];
        _fx.delayTapBPM = 120;
        if (phase != 1) _fx.reverbSendEnabled = YES;
        if (phase != 0) _fx.delaySendEnabled = YES;
        [self onQueue:^{}];
        [self render:4800 source:nil into:nil];
        uint64_t impulse = _pump.renderedFrames;
        captures[phase] = [NSMutableData data];
        [self render:14400 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:captures[phase]];
        _fx.reverbSendEnabled = NO;
        _fx.delaySendEnabled = NO;
        [self onQueue:^{}];
        [self render:96000 - 14400 source:nil into:captures[phase]];
        [self onQueue:^{ [self->_fx setConnected:NO format:nil maximumFrameCount:kMaxFrames]; }];
    }
    const float *reverb = captures[0].bytes, *delay = captures[1].bytes, *both = captures[2].bytes;
    NSUInteger samples = captures[2].length / sizeof(float);
    XCTAssertEqual(captures[0].length, captures[2].length);
    XCTAssertEqual(captures[1].length, captures[2].length);
    float worst = 0;
    for (NSUInteger i = 0; i < samples; i++) {
        float dry = i < 2 ? 0.5f : 0.0f;
        worst = MAX(worst, fabsf(both[i] - (reverb[i] + delay[i] - dry)));
    }
    XCTAssertLessThan(worst, 1e-3f, @"the returns did not sum");
    XCTAssertGreaterThan(VibeTestRMS(captures[0], 0, 24000, 24000), 1e-5, @"the reverb's tail after the release");
    XCTAssertGreaterThan(VibeTestRMS(captures[1], 0, 24000 - 64, 256), 1e-3, @"the delay's echo after the release");
}

- (void)testTheLowKillCutsAndRestsExactly {
    [self connectAt:kRate];
    _fx.lowKillEnabled = YES;
    [self onQueue:^{}];
    [self render:9600 source:nil into:nil]; // the 80 ms sweep
    NSMutableData *cut = [NSMutableData data];
    [self render:24000 source:^float(uint64_t frame, int channel) { return 0.25f * sinf((float)(2 * M_PI * 20 * frame / kRate)); } into:cut];
    XCTAssertLessThan(VibeTestRMS(cut, 0, 12000, 12000) / (0.25 / sqrt(2)), 0.02, @"20 Hz survives the low kill");
    _fx.lowKillEnabled = NO;
    [self onQueue:^{}];
    // The sweep back, the settle, and the rest.
    [self render:24000 source:nil into:nil];
    uint64_t rested = _fx.unitRenders;
    NSMutableData *capture = [NSMutableData data];
    uint64_t first = _pump.renderedFrames;
    [self render:48000 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:capture];
    [self assertCapture:capture isNoiseFrom:first];
    XCTAssertEqual(_fx.unitRenders, rested, @"a parked low kill rendered");
}

// The pad's writers: a level lands the gate at that fraction of the held
// key's full level with no swell, a second level moves it from there, and
// zero closes the send, which rests after its tail as a release does.
- (void)testASendLevelLandsTheGateAndZeroRestsIt {
    [self connectAt:kRate];
    _fx.delayTapBPM = 120;
    _fx.delaySendLevel = 0.5f;
    [self onQueue:^{}];
    [self render:4800 source:nil into:nil];
    XCTAssertEqualWithAccuracy(_fx.delaySendLevel, 0.5f, 1e-6);
    XCTAssertFalse(_fx.delaySendEnabled, @"a level is not a held key");
    XCTAssertGreaterThan(_fx.unitRenders, 0ull, @"a send at a level renders its units");
    NSMutableData *half = [NSMutableData data];
    uint64_t impulse = _pump.renderedFrames;
    [self render:24000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:half];
    // No swell: six seconds on, the gate is where the level put it.
    [self render:(NSUInteger)(kRate * 7) source:nil into:nil];
    NSMutableData *later = [NSMutableData data];
    impulse = _pump.renderedFrames;
    [self render:24000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:later];
    double tapHalf = VibeTestRMS(half, 0, 12000 - 64, 256);
    XCTAssertGreaterThan(tapHalf, 0.00001);
    XCTAssertEqualWithAccuracy(VibeTestRMS(later, 0, 12000 - 64, 256), tapHalf, tapHalf * 0.05, @"the level swelled");
    // Twice the level is twice the echo.
    _fx.delaySendLevel = 1.0f;
    [self onQueue:^{}];
    [self render:4800 source:nil into:nil];
    NSMutableData *full = [NSMutableData data];
    impulse = _pump.renderedFrames;
    [self render:24000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:full];
    XCTAssertEqualWithAccuracy(VibeTestRMS(full, 0, 12000 - 64, 256), tapHalf * 2, tapHalf * 0.1);
    // Zero closes the send; the trail rings out and the stage rests.
    _fx.delaySendLevel = 0;
    [self onQueue:^{}];
    [self render:(NSUInteger)(kRate * 40) source:nil into:nil];
    uint64_t rested = _fx.unitRenders;
    NSMutableData *silence = [NSMutableData data];
    [self render:48000 source:nil into:silence];
    XCTAssertEqual(_fx.unitRenders, rested, @"a rested stage rendered");
    XCTAssertEqual(VibeTestRMS(silence, 0, 0, 48000), 0.0);
}

// A cutoff written directly engages the filter there — between the mac's
// two cutoffs, where no toggle can put it — and parked rests it exactly.
- (void)testADirectCutoffEngagesAndParkedRestsExactly {
    [self connectAt:kRate];
    _fx.lowKillCutoffHz = 300;
    [self onQueue:^{}];
    XCTAssertEqualWithAccuracy(_fx.lowKillCutoffHz, 300, 1e-6);
    XCTAssertFalse(_fx.lowKillEnabled, @"a cutoff is not the toggle");
    [self render:9600 source:nil into:nil]; // the 80 ms sweep
    NSMutableData *cut = [NSMutableData data];
    [self render:24000 source:^float(uint64_t frame, int channel) { return 0.25f * sinf((float)(2 * M_PI * 40 * frame / kRate)); } into:cut];
    XCTAssertLessThan(VibeTestRMS(cut, 0, 12000, 12000) / (0.25 / sqrt(2)), 0.05, @"40 Hz survives a 300 Hz cutoff");
    NSMutableData *kept = [NSMutableData data];
    [self render:24000 source:^float(uint64_t frame, int channel) { return 0.25f * sinf((float)(2 * M_PI * 2000 * frame / kRate)); } into:kept];
    XCTAssertGreaterThan(VibeTestRMS(kept, 0, 12000, 12000) / (0.25 / sqrt(2)), 0.8, @"2 kHz lost under a 300 Hz cutoff");
    _fx.lowKillCutoffHz = 0;
    [self onQueue:^{}];
    [self render:24000 source:nil into:nil]; // the sweep back, the settle, and the rest
    uint64_t rested = _fx.unitRenders;
    NSMutableData *capture = [NSMutableData data];
    uint64_t first = _pump.renderedFrames;
    [self render:48000 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:capture];
    [self assertCapture:capture isNoiseFrom:first];
    XCTAssertEqual(_fx.unitRenders, rested, @"a parked low kill rendered");
}

- (void)testTheChainFollowsARateChange {
    [self connectAt:kRate];
    [self attachPumpAt:96000];
    [self connectAt:96000];
    _fx.reverbSendEnabled = YES;
    [self onQueue:^{}];
    NSMutableData *capture = [NSMutableData data];
    uint64_t impulse = _pump.renderedFrames + 9600;
    [self render:96000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:capture];
    XCTAssertGreaterThan(VibeTestRMS(capture, 0, 9600 + 4800, 9600), 0.000001, @"the reverb tail at the new rate");
    const float *out = capture.bytes;
    for (NSUInteger i = 0; i < capture.length / sizeof(float); i++) {
        XCTAssertTrue(isfinite(out[i]));
    }
}

- (void)testDeadUnitsAreRehostedAtTheSameRateWhileConnectedOrBypassed {
    for (NSNumber *bypassed in @[@NO, @YES]) {
        _fx.lowKillCutoffHz = 300;
        _fx.reverbSendLevel = 0.6f;
        _fx.delaySendEnabled = YES;
        _fx.delayTapBPM = 135;
        [self connectAt:kRate];
        [self render:kBlock source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:nil];
        VibeFXChain *old = _fx.chain;
        [self onQueue:^{
            self->_renderLeaveWork = [NSMutableArray array];
            if (bypassed.boolValue) [self->_fx setConnected:NO format:nil maximumFrameCount:kMaxFrames];
            for (NSUInteger i = 0; i < 10; i++) {
                XCTAssertTrue([self->_fx debugUninitializeUnitAtIndex:i]);
            }
            [self->_fx markDead];
            [self->_fx markDead];
            XCTAssertFalse(self->_fx.connected);
            XCTAssertEqual(self->_fx.hostedUnitCount, 0u);
            XCTAssertTrue(self->_fx.chain == NULL);
        }];
        uint64_t rendered = _fx.unitRenders;
        uint64_t first = _pump.renderedFrames;
        NSMutableData *dry = [NSMutableData data];
        // Old cutoff and swell steps run while the hosting is absent.
        [self render:48000 source:^float(uint64_t frame, int channel) { return VibeTestNoise(frame, channel); } into:dry];
        [self assertCapture:dry isNoiseFrom:first];
        XCTAssertEqual(_fx.unitRenders, rendered);
        XCTAssertEqualWithAccuracy(_fx.lowKillCutoffHz, 300, 1e-6);
        XCTAssertEqualWithAccuracy(_fx.reverbSendLevel, 0.6f, 1e-6);
        XCTAssertTrue(_fx.delaySendEnabled);
        XCTAssertEqualWithAccuracy(_fx.delayTapBPM, 135, 1e-6);
        [self connectAt:kRate];
        XCTAssertTrue(_fx.chain != old, @"the dead hosting was reused at the unchanged rate");
        [self onQueue:^{
            XCTAssertGreaterThan(self->_renderLeaveWork.count, 0u);
            for (dispatch_block_t work in self->_renderLeaveWork) work();
            self->_renderLeaveWork = nil;
        }];
        NSMutableData *wet = [NSMutableData data];
        uint64_t impulse = _pump.renderedFrames + 4800;
        [self render:48000 source:^float(uint64_t frame, int channel) { return frame == impulse ? 0.5f : 0.0f; } into:wet];
        XCTAssertGreaterThan(VibeTestRMS(wet, 0, 9600, 9600), 0.000001, @"the rebuilt effects produced no tail");
        const float *out = wet.bytes;
        for (NSUInteger i = 0; i < wet.length / sizeof(float); i++) XCTAssertTrue(isfinite(out[i]));
    }
}

@end
