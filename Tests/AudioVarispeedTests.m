//
//  AudioVarispeedTests.m
//  VibeTests
//
//  The pitch stage on its own, through its C API, against a sawtooth ramp:
//  each source frame's value is its position in a period of 65536 frames,
//  exact in float32, and the converter passes a ramp through, since its
//  kernel passes DC and is symmetric. So every output frame reads back as
//  the stage's position, to about 0.004 of a frame, and a skipped or repeated
//  frame anywhere shows. The player's own suite (AudioPlayerRenderTests)
//  measures quality and the edges through the real render.
//

#import <XCTest/XCTest.h>
#import "AudioVarispeed.h"
#include <stdatomic.h>

static const uint32_t kPeriod = 65536;
static const double kStep = 1.0 / kPeriod;   // a frame's rise
static const uint32_t kMaxFrames = 4096;
// Values either side of the ramp's wrap that are not read. The converter
// rings on the full-scale step there, up to about 9% of it either side
// (Gibbs), so a frame near the wrap can read as a position up to about 6000
// frames from it.
static const double kWrapGuard = 8000;

// The source: the ramp from the frame counter at `context`.
static OSStatus VibeTestRampInput(void *context, const AudioTimeStamp *stamp, UInt32 frames,
                                  AudioBufferList *into) CA_REALTIME_API {
    uint64_t *next = context;
    for (UInt32 c = 0; c < into->mNumberBuffers; c++) {
        float *out = into->mBuffers[c].mData;
        for (UInt32 n = 0; n < frames; n++) {
            out[n] = (float)((double)((*next + n) % kPeriod) * kStep);
        }
    }
    *next += frames;
    return noErr;
}

// One frame's step from the last, in frames, across the ramp's wrap; NAN when
// either frame is too near the wrap to read.
static double VibeTestStep(double previous, double current) {
    if (previous < kWrapGuard || previous > kPeriod - kWrapGuard || current < kWrapGuard || current > kPeriod - kWrapGuard) {
        return NAN;
    }
    double step = current - previous;
    return step < -(double)kPeriod / 2 ? step + kPeriod : step;
}

@interface AudioVarispeedTests : XCTestCase
@end

@implementation AudioVarispeedTests

// A seeded random schedule of pitches, zero among them, and slice sizes from
// 1 to 4096, with every replaced table retired at once. A slice the converter
// renders moves each frame between 0.82 and 1.18 frames on. Any other slice,
// zero pitch or a replay, is the source exactly, one frame at a time. The
// frame where the converter joins follows the last direct one, and the one
// where it leaves follows the converter's next position.
- (void)checkRandomScheduleWithChannels:(uint32_t)channels seed:(uint32_t)seed {
    __block uint32_t state = seed;
    uint32_t (^random)(uint32_t) = ^uint32_t(uint32_t bound) {
        state = state * 1664525u + 1013904223u;
        return (state >> 8) % bound;
    };
    VibeVarispeed *stage = VibeVarispeedCreate(channels, kMaxFrames);
    float left[kMaxFrames], right[kMaxFrames];
    VibeStereoBufferList out = { channels, {{ 1, (UInt32)sizeof(left), left }, { 1, (UInt32)sizeof(right), right }} };
    AudioTimeStamp stamp = {0};
    uint64_t source = 0, frames = 0;
    double previous = NAN;
    BOOL previousConverted = NO, everConverted = NO;
    NSUInteger slices = 0, failures = 0;
    while (frames < 600000 && failures < 5) {
        if (random(100) < 15) {
            uint32_t pick = random(10);
            double percent = pick < 3 ? 0 : pick == 3 ? 16 : pick == 4 ? -16 : pick == 5 ? 0.1 * ((int)random(3) - 1)
                                                                                         : ((double)random(3201) - 1600) / 100;
            VibeVarispeedTable *replaced = NULL;
            XCTAssertTrue(VibeVarispeedSetPitch(stage, percent, &replaced));
            if (replaced) {
                VibeVarispeedRetire(stage, replaced);
            }
        }
        UInt32 count = 1 + random(random(4) ? 600 : kMaxFrames);
        BOOL converted = VibeVarispeedEngaged(stage) && VibeVarispeedWanted(stage);
        out.mBuffers[0].mDataByteSize = out.mBuffers[1].mDataByteSize = count * (UInt32)sizeof(float);
        XCTAssertEqual(VibeVarispeedRender(stage, VibeTestRampInput, &source, &stamp, count, (AudioBufferList *)&out), noErr);
        for (UInt32 n = 0; n < count && failures < 5; n++) {
            double position = left[n] / kStep, step = VibeTestStep(previous, position);
            if (channels == 2 && left[n] != right[n]) {
                XCTFail(@"slice %lu frame %u: the channels differ", (unsigned long)slices, n);
                failures++;
            }
            if (!isfinite(left[n])) {
                XCTFail(@"slice %lu frame %u: not finite", (unsigned long)slices, n);
                failures++;
                continue;
            }
            if (!converted && position != round(position)) {
                XCTFail(@"slice %lu frame %u: a direct frame is not the source's: %.4f", (unsigned long)slices, n, position);
                failures++;
            }
            if (!isnan(step)) {
                BOOL edge = n == 0 && converted != previousConverted;
                double low = converted ? 0.82 : 1, high = converted ? 1.18 : 1;
                if (edge) {
                    // Joining: the frame after the last direct one. Leaving:
                    // the converter's next position, rounded.
                    low = converted ? 0.95 : 0.3;
                    high = converted ? 1.05 : 1.7;
                }
                if (step < low - 1e-9 || step > high + 1e-9) {
                    XCTFail(@"slice %lu frame %u (%@%@): stepped %.4f frames", (unsigned long)slices, n,
                            converted ? @"converted" : @"direct", edge ? @", an edge" : @"", step);
                    failures++;
                }
            }
            previous = position;
        }
        previousConverted = converted;
        everConverted |= converted;
        frames += count;
        slices++;
    }
    XCTAssertTrue(everConverted, @"the schedule never engaged the converter");
    XCTAssertGreaterThan(VibeVarispeedRenders(stage), 0ull);
    VibeVarispeedFree(stage);
}

- (void)testARandomScheduleSkipsAndRepeatsNoFrame {
    for (uint32_t seed = 1; seed <= 4; seed++) {
        [self checkRandomScheduleWithChannels:2 seed:seed * 7919];
    }
}

- (void)testARandomScheduleSkipsAndRepeatsNoFrameInMono {
    [self checkRandomScheduleWithChannels:1 seed:104729];
}

// The pitch moved from another thread while the render runs, the way the
// player queue moves it: a replaced table is retired only once the render is
// seen outside the stage. Every frame steps on between 0.3 and 1.7 frames,
// so nothing is skipped, repeated or torn whatever lands mid-slice. Settled
// at zero after, the stage is the source exactly. Run it under the thread
// sanitizer when the stage's threading changes.
- (void)testPitchChangesFromAnotherThreadKeepTheStreamWhole {
    VibeVarispeed *stage = VibeVarispeedCreate(2, kMaxFrames);
    __block _Atomic int inside = 0, done = 0;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint32_t state = 31337;
        while (!atomic_load(&done)) {
            state = state * 1664525u + 1013904223u;
            double percent = (state >> 8) % 5 == 0 ? 0 : ((double)((state >> 12) % 3201) - 1600) / 100;
            VibeVarispeedTable *replaced = NULL;
            VibeVarispeedSetPitch(stage, percent, &replaced);
            if (replaced) {
                while (atomic_load(&inside)) {
                }
                VibeVarispeedRetire(stage, replaced);
            }
            usleep(50 + (state >> 20) % 200);
        }
        dispatch_semaphore_signal(finished);
    });
    float left[kMaxFrames], right[kMaxFrames];
    VibeStereoBufferList out = { 2, {{ 1, (UInt32)sizeof(left), left }, { 1, (UInt32)sizeof(right), right }} };
    AudioTimeStamp stamp = {0};
    uint64_t source = 0;
    double previous = NAN;
    uint32_t state = 4242;
    NSUInteger failures = 0;
    for (NSUInteger slice = 0; slice < 20000 && failures < 5; slice++) {
        state = state * 1664525u + 1013904223u;
        UInt32 count = 1 + (state >> 8) % 1024;
        out.mBuffers[0].mDataByteSize = out.mBuffers[1].mDataByteSize = count * (UInt32)sizeof(float);
        atomic_store(&inside, 1);
        VibeVarispeedRender(stage, VibeTestRampInput, &source, &stamp, count, (AudioBufferList *)&out);
        atomic_store(&inside, 0);
        for (UInt32 n = 0; n < count && failures < 5; n++) {
            double position = left[n] / kStep, step = VibeTestStep(previous, position);
            if (!isfinite(left[n]) || left[n] != right[n] || (!isnan(step) && (step < 0.3 || step > 1.7))) {
                XCTFail(@"slice %lu frame %u: %.4f after %.4f", (unsigned long)slice, n, position, previous);
                failures++;
            }
            previous = position;
        }
    }
    atomic_store(&done, 1);
    XCTAssertEqual(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
    VibeVarispeedTable *replaced = NULL;
    VibeVarispeedSetPitch(stage, 0, &replaced);
    for (int settle = 0; settle < 4; settle++) {
        VibeVarispeedRender(stage, VibeTestRampInput, &source, &stamp, kMaxFrames, (AudioBufferList *)&out);
    }
    for (UInt32 n = 0; n < kMaxFrames; n++) {
        double position = left[n] / kStep;
        if (position != round(position) || (n && VibeTestStep(left[n - 1] / kStep, position) != 1 &&
                                            !isnan(VibeTestStep(left[n - 1] / kStep, position)))) {
            XCTFail(@"settled at zero, frame %u is not the source's: %.4f", n, position);
            break;
        }
    }
    VibeVarispeedFree(stage);
}

// At zero pitch, every slice size from 1 to 4096 is the source exactly, and
// the stage copies nothing.
- (void)testZeroPitchIsTheSourceAtEverySliceSize {
    VibeVarispeed *stage = VibeVarispeedCreate(2, kMaxFrames);
    float left[kMaxFrames], right[kMaxFrames];
    VibeStereoBufferList out = { 2, {{ 1, (UInt32)sizeof(left), left }, { 1, (UInt32)sizeof(right), right }} };
    AudioTimeStamp stamp = {0};
    uint64_t source = 0;
    for (UInt32 count = 1; count <= kMaxFrames; count = count < 64 ? count + 1 : count * 2 - 1) {
        uint64_t first = source;
        out.mBuffers[0].mDataByteSize = out.mBuffers[1].mDataByteSize = count * (UInt32)sizeof(float);
        VibeVarispeedRender(stage, VibeTestRampInput, &source, &stamp, count, (AudioBufferList *)&out);
        for (UInt32 n = 0; n < count; n++) {
            float expected = (float)((double)((first + n) % kPeriod) * kStep);
            if (left[n] != expected || right[n] != expected) {
                XCTFail(@"a slice of %u: frame %u is not the source's", count, n);
                break;
            }
        }
    }
    XCTAssertEqual(VibeVarispeedHistoryWrites(stage), 0ull);
    XCTAssertEqual(VibeVarispeedRenders(stage), 0ull);
    VibeVarispeedFree(stage);
}

@end
