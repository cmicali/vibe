//
// The iOS scrubber's pinch-zoom range: how deep the zoom may go before the
// settled envelope bitmap outgrows the texture ceiling or the byte budget, and
// the two clamps that keep the user's REQUEST and what the view DRAWS apart.
// That split is the point of the header — the floor moves with the layout, and
// a rotation must not rewrite what was persisted.
//

#import <XCTest/XCTest.h>

#import "WaveformZoomMath.h"

@interface WaveformZoomMathTests : XCTestCase
@end

@implementation WaveformZoomMathTests

// The shipping layouts, so a change to either ceiling shows up as a change to
// numbers someone can recognize. Waveform heights are TrackPageCell's.
static const CGFloat kPhoneWidth = 393;         // iPhone 16 portrait
static const CGFloat kPhoneHeight = 180;        // kCellWaveformHeight
static const CGFloat kPhoneScale = 3;
static const CGFloat kPadWidth = 1366;          // iPad 12.9" landscape
static const CGFloat kPadHeight = 120;          // kCellWaveformHeightLandscape
static const CGFloat kPadScale = 2;

static CGFloat PhoneMinimum(void) {
    return VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPhoneHeight, kPhoneScale);
}

#pragma mark - The floor

// The whole point of the floor: the bake it allows must fit both ceilings, on
// every layout. Asserted from the definition rather than from a magic number,
// so retuning kVibeMaxBakeImageBytes does not falsify the test that guards it.
- (void)testDeepestZoomBakesWithinBothCeilings {
    const CGFloat widths[] = {320, 375, 393, 430, 744, 852, 1024, 1366};
    const CGFloat heights[] = {kPhoneHeight, kPadHeight};
    const CGFloat scales[] = {1, 2, 3};
    for (size_t w = 0; w < sizeof(widths) / sizeof(*widths); w++) {
        for (size_t h = 0; h < sizeof(heights) / sizeof(*heights); h++) {
            for (size_t s = 0; s < sizeof(scales) / sizeof(*scales); s++) {
                CGFloat minimum = VibeWaveformMinimumVisibleFraction(widths[w], heights[h], scales[s]);
                CGFloat virtualWidthPx = widths[w] / minimum * scales[s];
                CGFloat bytes = virtualWidthPx * heights[h] * scales[s] * 4;
                XCTAssertLessThanOrEqual(virtualWidthPx, kVibeMaxBakeImagePixels + 1,
                        @"%g pt @%gx would bake past the texture ceiling", widths[w], scales[s]);
                XCTAssertLessThanOrEqual(bytes, kVibeMaxBakeImageBytes + 1,
                        @"%g x %g pt @%gx would bake past the byte budget",
                        widths[w], heights[h], scales[s]);
            }
        }
    }
}

// The floor has to leave a usable range, or the feature is a no-op: the
// shipping layouts must all zoom in at least twice as far as they rest at.
- (void)testShippingLayoutsAffordRealZoom {
    XCTAssertLessThan(PhoneMinimum(), kVibeWaveformDefaultZoomFraction / 2);
    XCTAssertLessThan(VibeWaveformMinimumVisibleFraction(kPadWidth, kPadHeight, kPadScale),
                      kVibeWaveformDefaultZoomFraction / 2);
    XCTAssertGreaterThan(PhoneMinimum(), 0);
}

// A shorter waveform fits a wider bitmap in the same bytes, so it earns deeper
// zoom; a wider view needs a wider bitmap for the same depth, so it gets less.
- (void)testFloorMovesWithGeometry {
    XCTAssertLessThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPadHeight, kPhoneScale),
                      PhoneMinimum());
    XCTAssertGreaterThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth * 2, kPhoneHeight, kPhoneScale),
                         PhoneMinimum());
    XCTAssertGreaterThan(VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPhoneHeight, kPhoneScale * 2),
                         PhoneMinimum());
}

// Degenerate geometry degrades to the whole track, never to a division.
- (void)testDegenerateGeometryAffordsNoZoom {
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(0, kPhoneHeight, kPhoneScale), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(kPhoneWidth, 0, kPhoneScale), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPhoneHeight, 0), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(-1, -1, -1), 1);
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(NAN, kPhoneHeight, kPhoneScale), 1);
    // A view so wide the un-zoomed track already exceeds the ceilings.
    XCTAssertEqual(VibeWaveformMinimumVisibleFraction(20000, kPhoneHeight, kPhoneScale), 1);
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

// Garbage in either argument draws the whole track — the safest picture, and
// the one that cannot hide a geometry bug behind a plausible zoom.
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

// The reason the two clamps exist separately. A zoom committed on a layout
// that allowed it, then carried to one that does not, draws shallow WITHOUT
// the stored request changing — so rotating back restores the original depth,
// and the persisted value survives a launch in either orientation.
- (void)testDeepRequestSurvivesAShallowerLayout {
    CGFloat deep = VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPadHeight, kPhoneScale);
    CGFloat stored = VibeWaveformClampRequestedFraction(deep);
    XCTAssertEqual(stored, deep, @"the request is not the one that gets clamped");

    CGFloat shallowFloor = VibeWaveformMinimumVisibleFraction(kPadWidth, kPhoneHeight, kPadScale);
    XCTAssertGreaterThan(shallowFloor, deep, @"the layouts must actually differ, or this proves nothing");
    XCTAssertEqual(VibeWaveformClampVisibleFraction(stored, shallowFloor), shallowFloor);

    // Back to the layout that afforded it, and the original depth returns.
    CGFloat deepFloor = VibeWaveformMinimumVisibleFraction(kPhoneWidth, kPadHeight, kPhoneScale);
    XCTAssertEqual(VibeWaveformClampVisibleFraction(stored, deepFloor), deep);
}

@end
