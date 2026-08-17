//
//  WaveformZoomMath.h
//  Vibe
//
//  How deep the iOS scrubber's pinch zoom may go, as a function of the
//  geometry alone — no view, no layer. WaveformScrubberView feeds it the view
//  size and the display scale and draws at whatever comes back.
//
//  Shared rather than iOS-only because it is arithmetic with no UIKit in it;
//  the mac waveform view has no zoom model and never calls this.
//

#import <Foundation/Foundation.h>

// Fraction of the track visible across the view at rest: the DJ zoom level,
// and the value a launch with nothing persisted comes up at.
static const CGFloat kVibeWaveformDefaultZoomFraction = 0.48;

// The absolute range the STORED request is held to, independent of any
// geometry — a hair under the deepest any layout could allow. It exists so a
// corrupt or hand-written defaults value cannot store something absurd, and so
// the request stays a sane number to persist. What is actually DRAWN is
// clamped further, against the ceilings below.
static const CGFloat kVibeWaveformMinimumZoomFraction = 0.01;

// A CALayer whose contents exceed the GPU texture ceiling renders BLANK. The
// bake degrades rather than failing there — it drops its scale and lets resize
// gravity stretch the bitmap back, softening the bars — but a zoom deep enough
// to need that is a zoom drawn softer than the device can show, so this is
// where the depth stops. Shared with the bake itself, which reads the same
// number when it decides whether to reduce scale.
static const CGFloat kVibeMaxBakeImagePixels = 16384;

// What one baked envelope may occupy. Up to three pager cells hold one at a
// time and they all bake at the same zoom, so the app's worst case is three of
// these. The texture ceiling alone does not bound this: a 180pt-tall waveform
// at 3x is 540px, and 16384 x 540 x 4 is 35MB a cell, over 100MB across the
// pager. This is the number that makes the worst case chosen rather than
// accidental.
static const CGFloat kVibeMaxBakeImageBytes = 24 * 1024 * 1024;

// The deepest zoom whose bake fits both ceilings, as a visible fraction. The
// bake is the whole track at viewWidth / fraction, so a smaller fraction is a
// wider bitmap; solving each ceiling for the widest allowed virtual width and
// taking the tighter gives the floor.
//
// Returns 1.0 — no zoom at all — when even the un-zoomed track will not fit,
// and for any degenerate input, so the clamp below degrades to the whole track
// rather than to nonsense.
static inline CGFloat VibeWaveformMinimumVisibleFraction(CGFloat viewWidthPt,
                                                         CGFloat viewHeightPt,
                                                         CGFloat scale) {
    // Written so a NaN or infinite input lands here rather than on a division.
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

// What the view DRAWS at: the user's request against this geometry's floor.
// 1.0 is the zoom-out stop, where the whole track spans exactly the view
// width. The request itself is never rewritten by this — the floor moves with
// the layout, and clamping the stored value would shallow a persisted zoom
// permanently on one rotation.
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

// The STORED request's clamp: the absolute design range and nothing else.
// Anything outside it — a corrupt defaults value, a missing key read back as
// 0, a NaN — lands on the default rather than on a limit, so garbage reads as
// "never set" instead of as maximum zoom.
static inline CGFloat VibeWaveformClampRequestedFraction(CGFloat requested) {
    if (!(requested >= kVibeWaveformMinimumZoomFraction) || !(requested <= 1)) {
        return kVibeWaveformDefaultZoomFraction;
    }
    return requested;
}
