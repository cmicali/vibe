//
// The playback-UI tick rate rule: the Hz that steps the playhead about
// kVibeUITargetPxPerTick device pixels, clamped to [3, 30]. Ordinary songs
// must land on the floor — they cost exactly what they always did — and short
// samples on the cap.
//

#import <XCTest/XCTest.h>

#import "UIUpdateMath.h"

@interface UIUpdateMathTests : XCTestCase
@end

@implementation UIUpdateMathTests

// A typical waveform: ~600 pt wide on a Retina display.
static const double kWidthPx = 1200.0;

// The shipping default cap; the cap's own cases pass it explicitly.
static const NSUInteger kCap = 30;

static NSUInteger Hz(double widthPx, NSTimeInterval duration, double rate) {
    return VibeUIUpdateHzForPlayhead(widthPx, duration, rate, kCap);
}

- (void)testOrdinarySongRestsAtTheFloor {
    // 1200 px / 240 s = 5 px/s, which asks for 2.5 Hz.
    XCTAssertEqual(Hz(kWidthPx, 240.0, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, 60.0 * 60.0, 1.0), kVibeUIUpdateHzMin); // an hour-long mix
    // The floor's own boundary: 6 px/s is exactly 3 Hz at 2 px a tick.
    XCTAssertEqual(Hz(kWidthPx, 200.0, 1.0), kVibeUIUpdateHzMin);
}

- (void)testShortSampleHitsTheCap {
    // 1200 px / 5 s = 240 px/s, which asks for 120 Hz.
    XCTAssertEqual(Hz(kWidthPx, 5.0, 1.0), kCap);
    XCTAssertEqual(Hz(kWidthPx, 0.25, 1.0), kCap);
}

- (void)testMidRangeScalesWithTheSpeed {
    // 1200 px / 30 s = 40 px/s → 20 Hz.
    XCTAssertEqual(Hz(kWidthPx, 30.0, 1.0), (NSUInteger)20);
    // 1200 px / 60 s = 20 px/s → 10 Hz.
    XCTAssertEqual(Hz(kWidthPx, 60.0, 1.0), (NSUInteger)10);
    // Rounds up, so the step never exceeds the target.
    XCTAssertEqual(Hz(kWidthPx, 55.0, 1.0), (NSUInteger)11);
}

- (void)testFasterRateAsksForMoreTicks {
    // The pitch fader moves the playhead, so it moves the rate. +16% on a
    // track that sits mid-range at 1.0.
    XCTAssertEqual(Hz(kWidthPx, 60.0, 1.16), (NSUInteger)12);
    XCTAssertEqual(Hz(kWidthPx, 60.0, 0.84), (NSUInteger)9);
    // A rate change cannot escape the clamps.
    XCTAssertEqual(Hz(kWidthPx, 240.0, 1.16), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, 5.0, 0.84), kCap);
}

- (void)testWiderWaveformAsksForMoreTicks {
    // The same track on a wider window, or on a Retina display against a
    // non-Retina one, moves more pixels per second.
    XCTAssertEqual(Hz(600.0, 60.0, 1.0), (NSUInteger)5);
    XCTAssertEqual(Hz(2400.0, 60.0, 1.0), (NSUInteger)20);
}

- (void)testDegenerateInputsRestAtTheFloor {
    // Duration 0 is the Loading gap and the end-of-playlist park, where the
    // duration cache is zeroed.
    XCTAssertEqual(Hz(kWidthPx, 0.0, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, -1.0, 1.0), kVibeUIUpdateHzMin);
    // A view with no width yet, or off-screen.
    XCTAssertEqual(Hz(0.0, 60.0, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(-10.0, 60.0, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, 60.0, 0.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, 60.0, -1.0), kVibeUIUpdateHzMin);
    // NaN and infinity must land on a clamp rather than on an undefined cast.
    XCTAssertEqual(Hz(NAN, 60.0, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, NAN, 1.0), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(kWidthPx, 60.0, NAN), kVibeUIUpdateHzMin);
    XCTAssertEqual(Hz(INFINITY, 60.0, 1.0), kCap);
    XCTAssertEqual(Hz(kWidthPx, INFINITY, 1.0), kVibeUIUpdateHzMin);
}

// Settings > Advanced offers 3, 30 and 60 Hz, and the getter snaps a
// persisted value to one of them — but the rule must hold for any caller.
- (void)testCapIsTheCeiling {
    // A five-second sample asks for 120 Hz and takes whatever it is allowed.
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 5.0, 1.0, 60), (NSUInteger)60);
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 5.0, 1.0, 30), (NSUInteger)30);
    // The floor cap is the fixed 3 Hz tick the app had before this rule.
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 5.0, 1.0, 3), kVibeUIUpdateHzMin);
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 30.0, 1.0, 3), kVibeUIUpdateHzMin);
    // A cap above what the playhead needs changes nothing: 40 px/s is 20 Hz
    // whether the ceiling is 30 or 60.
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 30.0, 1.0, 60), (NSUInteger)20);
    // A cap under the floor, or none at all, cannot tick slower than 3 Hz.
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 5.0, 1.0, 1), kVibeUIUpdateHzMin);
    XCTAssertEqual(VibeUIUpdateHzForPlayhead(kWidthPx, 5.0, 1.0, 0), kVibeUIUpdateHzMin);
}

- (void)testAlwaysWithinTheClamps {
    const double widths[] = {0.0, 1.0, 320.0, 1200.0, 8000.0, 1e9};
    const double durations[] = {0.0, 0.001, 1.0, 5.0, 240.0, 36000.0, 1e9};
    const double rates[] = {0.0, 0.84, 1.0, 1.16, 4.0};
    for (size_t w = 0; w < sizeof(widths) / sizeof(*widths); w++) {
        for (size_t d = 0; d < sizeof(durations) / sizeof(*durations); d++) {
            for (size_t r = 0; r < sizeof(rates) / sizeof(*rates); r++) {
                NSUInteger hz = Hz(widths[w], durations[d], rates[r]);
                XCTAssertGreaterThanOrEqual(hz, kVibeUIUpdateHzMin);
                XCTAssertLessThanOrEqual(hz, kCap);
            }
        }
    }
}

@end
