//
//  WaveformZoomMath.h
//  Vibe
//
//  How deep the iOS scrubber's pinch zoom may go. Shared only because it has
//  no UIKit in it; the mac view has no zoom.
//

#import <Foundation/Foundation.h>

// Fraction of the track visible across the view at rest: the DJ zoom level,
// and the value a launch with nothing persisted comes up at.
static const CGFloat kVibeWaveformDefaultZoomFraction = 0.48;

// The STORED request's floor, independent of the track, so a corrupt defaults
// value cannot persist something absurd. What is DRAWN is clamped further.
static const CGFloat kVibeWaveformMinimumZoomFraction = 0.000001;

// The widest content, in points. The render server keeps layer geometry in
// floats, and at 2^20 points a float still resolves a quarter of a 3x pixel.
static const CGFloat kVibeWaveformMaxVirtualWidth = 1 << 20;

// The finest a style that reads the summary alone may zoom: a bin of
// binFrames a point, three pixels a bin at 3x. The summary holds nothing
// finer than a bin, and the step styles read their levels linearly between
// columns, so a bin wider than this would show as a ramp.
static inline double VibeWaveformMinimumFramesPerPoint(double binFrames) {
    return binFrames;
}

// The finest with the stream's own frames read in for deep zoom: eight
// points a frame, where the line through the samples is the picture.
static const double kVibeWaveformMinimumDetailFramesPerPoint = 0.125;

// The deepest zoom: the track at no fewer than minimumFramesPerPoint frames a
// point, and no wider than kVibeWaveformMaxVirtualWidth. Without a track, the
// width alone. 1.0, no zoom, when even the whole track is wider, and for
// degenerate input.
static inline CGFloat VibeWaveformMinimumVisibleFraction(CGFloat viewWidthPt, double totalFrames,
                                                         double minimumFramesPerPoint) {
    // Negated so a NaN lands here rather than on a division.
    if (!(viewWidthPt > 0)) {
        return 1;
    }
    CGFloat maxVirtualWidthPt = kVibeWaveformMaxVirtualWidth;
    if (totalFrames > 0 && minimumFramesPerPoint > 0) {
        maxVirtualWidthPt = MIN(maxVirtualWidthPt, (CGFloat)(totalFrames / minimumFramesPerPoint));
    }
    if (!(maxVirtualWidthPt > viewWidthPt)) {
        return 1;
    }
    return viewWidthPt / maxVirtualWidthPt;
}

// What the view DRAWS at; 1.0 is the whole track across the view. Never written
// back to the request: the floor moves with the layout and the track, and
// clamping the stored value would shallow a persisted zoom for good on one
// short track.
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
