//
//  WaveformZoomMath.h
//  Vibe
//
//  How deep the iOS scrubber's pinch zoom may go, from geometry alone. Shared
//  only because it has no UIKit in it; the mac view has no zoom.
//

#import <Foundation/Foundation.h>

// Fraction of the track visible across the view at rest: the DJ zoom level,
// and the value a launch with nothing persisted comes up at.
static const CGFloat kVibeWaveformDefaultZoomFraction = 0.48;

// The STORED request's floor, independent of geometry, so a corrupt defaults
// value cannot persist something absurd. What is DRAWN is clamped further.
static const CGFloat kVibeWaveformMinimumZoomFraction = 0.01;

// A CALayer whose contents exceed the GPU texture ceiling renders BLANK. The
// bake reads this too, dropping its scale past it rather than failing, but a
// zoom that needs that is drawn softer than the device can show, so the depth
// stops here.
static const CGFloat kVibeMaxBakeImagePixels = 16384;

// What one baked envelope may occupy; up to three pager cells hold one each.
// The texture ceiling alone would allow 35MB a cell (16384 x 540px x 4 for a
// 180pt waveform at 3x), over 100MB across the pager.
static const CGFloat kVibeMaxBakeImageBytes = 24 * 1024 * 1024;

// The deepest zoom whose bake (the whole track at viewWidth / fraction) fits
// both ceilings. 1.0 — no zoom — when even the un-zoomed track will not fit,
// and for degenerate input.
static inline CGFloat VibeWaveformMinimumVisibleFraction(CGFloat viewWidthPt,
                                                         CGFloat viewHeightPt,
                                                         CGFloat scale) {
    // Negated so a NaN lands here rather than on a division.
    if (!(viewWidthPt > 0) || !(viewHeightPt > 0) || !(scale > 0)) {
        return 1;
    }
    CGFloat heightPx = viewHeightPt * scale;
    CGFloat widthPx = MIN(kVibeMaxBakeImagePixels,
                          kVibeMaxBakeImageBytes / (4 * heightPx));
    CGFloat maxVirtualWidthPt = widthPx / scale;
    if (!(maxVirtualWidthPt > viewWidthPt)) {
        return 1;
    }
    return viewWidthPt / maxVirtualWidthPt;
}

// What the view DRAWS at; 1.0 is the whole track across the view. Never written
// back to the request: the floor moves with the layout, and clamping the
// stored value would shallow a persisted zoom for good on one rotation.
static inline CGFloat VibeWaveformClampVisibleFraction(CGFloat requested,
                                                       CGFloat minimum) {
    if (!(minimum > 0) || !(minimum < 1)) {
        return 1;
    }
    if (!(requested > 0) || !(requested < 1)) {
        return 1;
    }
    return MAX(requested, minimum);
}

// The STORED request's clamp. Anything outside the range — corrupt, a missing
// key read as 0, a NaN — lands on the default, so garbage reads as "never set"
// rather than as maximum zoom.
static inline CGFloat VibeWaveformClampRequestedFraction(CGFloat requested) {
    if (!(requested >= kVibeWaveformMinimumZoomFraction) || !(requested <= 1)) {
        return kVibeWaveformDefaultZoomFraction;
    }
    return requested;
}
