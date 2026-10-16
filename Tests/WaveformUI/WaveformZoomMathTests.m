// The request and the drawn fraction are clamped apart: the floor moves with
// the layout and the track, and neither may rewrite what was persisted.

#import <XCTest/XCTest.h>

#import "WaveformZoomMath.h"

@interface WaveformZoomMathTests : XCTestCase
@end

@implementation WaveformZoomMathTests

// A shipping layout, and a song and a mix at 44.1 kHz.
static const CGFloat kPhoneWidth = 393;         // iPhone 16 portrait
static const CGFloat kPadWidth = 1366;          // iPad 12.9" landscape
static const double kSongFrames = 280.0 * 44100;
static const double kMixFrames = 66.0 * 60 * 44100;

static CGFloat PhoneMinimum(void) {
    return VibeWaveformMinimumVisibleFraction(kPhoneWidth, kSongFrames, VibeWaveformMinimumFramesPerPoint(256));
}

#pragma mark - The floor

// A zoom never reads finer than two bins a point, Detailed's two columns,
// and the content is no wider than the float geometry keeps sharp.
- (void)testDeepestZoomReadsNoFinerThanABinAndStaysInFloatRange {
    const CGFloat widths[] = {320, 393, 744, 1366};
    const double lengths[] = {44100, kSongFrames, kMixFrames, 24.0 * 3600 * 48000};
    for (size_t w = 0; w < sizeof(widths) / sizeof(*widths); w++) {
        for (size_t l = 0; l < sizeof(lengths) / sizeof(*lengths); l++) {
            CGFloat width = widths[w];
            double frames = lengths[l];
            double framesPerPoint = VibeWaveformMinimumFramesPerPoint(256);
            CGFloat minimum = VibeWaveformMinimumVisibleFraction(width, frames, framesPerPoint);
            if (minimum == 1) {
                continue;   // no zoom: the whole track already fits
            }
            CGFloat virtualWidth = width / minimum;
            XCTAssertGreaterThanOrEqual(frames / virtualWidth, framesPerPoint * (1 - 1e-9),
                                        @"%g pt over %g frames reads finer than a bin", width, frames);
            XCTAssertLessThanOrEqual(virtualWidth, kVibeWaveformMaxVirtualWidth * (1 + 1e-9));
        }
    }
}

// A 4:40 song on a phone zooms to under 2% of the track: four seconds across
// the view, against the old bitmap budget's 7 to 10%.
- (void)testShippingLayoutsAffordRealZoom {
    XCTAssertLessThan(PhoneMinimum(), 0.02);
    XCTAssertGreaterThan(PhoneMinimum(), 0);
    XCTAssertLessThan(VibeWaveformMinimumVisibleFraction(kPadWidth, kSongFrames, VibeWaveformMinimumFramesPerPoint(256)),
                      kVibeWaveformDefaultZoomFraction / 2);
}

// A longer track or finer bins zoom deeper; a wider view, less.
- (void)testFloorMovesWithTheTrackAndTheWidth {
    double framesPerPoint = VibeWaveformMinimumFramesPerPoint(256);
    XCTAssertLessThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth, kMixFrames, framesPerPoint), PhoneMinimum());
    XCTAssertLessThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth, kSongFrames, VibeWaveformMinimumFramesPerPoint(64)),
                      PhoneMinimum());
    XCTAssertGreaterThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth * 2, kSongFrames, framesPerPoint),
                         PhoneMinimum());
}

// Without a track, only the float range limits the width.
- (void)testNoTrackLimitsOnlyTheWidth {
    XCTAssertEqualWithAccuracy(VibeWaveformMinimumVisibleFraction(kPhoneWidth, 0, 0),
                               kPhoneWidth / kVibeWaveformMaxVirtualWidth, 1e-12);
}

- (void)testDegenerateInputAffordsNoZoom {
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(0, kSongFrames, 512), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(-1, kSongFrames, 512), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(NAN, kSongFrames, 512), 1);
    // A track so short the whole of it at the floor is narrower than the view.
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(kPhoneWidth, 44100, 512), 1);
}

#pragma mark - The drawn clamp

- (void)testRequestInRangeIsDrawnAsAsked {
    CGFloat minimum = PhoneMinimum();
    XCTAssertEqual(VibeWaveformClampVisibleFraction(0.48, minimum), 0.48);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(minimum, minimum), minimum);
}

- (void)testRequestBelowTheFloorIsDrawnAtTheFloor {
    CGFloat minimum = PhoneMinimum();
    XCTAssertEqual(VibeWaveformClampVisibleFraction(minimum / 4, minimum), minimum);
}

- (void)testZoomOutStopsAtTheWholeTrack {
    XCTAssertEqual(VibeWaveformClampVisibleFraction(1.0, 0.1), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(4.0, 0.1), 1);
}

- (void)testGarbageDrawsTheWholeTrack {
    XCTAssertEqual(VibeWaveformClampVisibleFraction(NAN, 0.1), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(-1, 0.1), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(0, 0.1), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(0.5, NAN), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(0.5, 0), 1);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(0.5, 1), 1);
}

#pragma mark - The stored clamp, and the round trip

- (void)testStoredRequestKeepsAnythingInTheAbsoluteRange {
    XCTAssertEqual(VibeWaveformClampRequestedFraction(0.48), 0.48);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(1.0), 1.0);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(kVibeWaveformMinimumZoomFraction),
                   kVibeWaveformMinimumZoomFraction);
}

// A missing defaults key reads back as 0, which must come up at the default
// rather than at maximum zoom.
- (void)testStoredRequestSendsGarbageToTheDefault {
    XCTAssertEqual(VibeWaveformClampRequestedFraction(0), kVibeWaveformDefaultZoomFraction);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(-3), kVibeWaveformDefaultZoomFraction);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(7), kVibeWaveformDefaultZoomFraction);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(NAN), kVibeWaveformDefaultZoomFraction);
    XCTAssertEqual(VibeWaveformClampRequestedFraction(INFINITY), kVibeWaveformDefaultZoomFraction);
}

// Why the two clamps are separate: a short track draws shallow WITHOUT
// changing the stored request, so the next long one restores the depth.
- (void)testDeepRequestSurvivesAShortTrack {
    double framesPerPoint = VibeWaveformMinimumFramesPerPoint(256);
    CGFloat deep = VibeWaveformMinimumVisibleFraction(kPhoneWidth, kMixFrames, framesPerPoint);
    CGFloat stored = VibeWaveformClampRequestedFraction(deep);
    XCTAssertEqual(stored, deep, @"the request is not the one that gets clamped");

    CGFloat shallowFloor = PhoneMinimum();
    XCTAssertGreaterThan(shallowFloor, deep, @"the tracks must actually differ, or this proves nothing");
    XCTAssertEqual(VibeWaveformClampVisibleFraction(stored, shallowFloor), shallowFloor);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(stored, deep), deep);
}

@end
