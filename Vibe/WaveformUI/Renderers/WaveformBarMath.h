//
//  WaveformBarMath.h
//  Vibe
//
//  The bar styles' view geometry: block quantization, the band, the seek band
//  and the pixel-snapped columns. Header-only and C++-free, so a plain .m can
//  import it.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "HelperMacros.h"

NS_ASSUME_NONNULL_BEGIN

// The block styles' quantization: the block under a view x, and how many whole
// blocks a progress fills, each flipping at its midpoint. Presentation only —
// the reported seek stays continuous.
static inline NSInteger VibeBlockIndexForX(CGFloat x, CGFloat width, NSInteger count) {
    NSInteger index = (NSInteger)(x / width * (CGFloat)count);
    return clampRange(index, (NSInteger)0, count - 1);
}
static inline NSInteger VibeBlockBoundaryForProgress(CGFloat progress, NSInteger count) {
    NSInteger boundary = (NSInteger)llround((double)count * progress);
    return clampRange(boundary, (NSInteger)0, count);
}

// Pixel-snapped, since half-lit edge pixels blur the crispest thing in the
// waveform. Bounds-relative; x may overshoot either edge.
static inline CGRect VibeSnappedColumnRect(CGFloat x, CGFloat columnWidth,
                                           CGFloat boundsWidth, CGFloat height, CGFloat scale) {
    CGFloat width = MAX(round(columnWidth * scale), 1) / scale;
    CGFloat left = floor((x - width / 2) * scale) / scale;
    left = clampRange(left, 0, MAX(0, boundsWidth - width));
    return CGRectMake(left, 0, width, height);
}

// The Detailed family's band, which 3-Band shares: bars reach this share of
// half the height either side of the midline. The one normalized-to-pixels
// scale, shared by the seek band, the morph's frame-skip heuristic, the masks
// and the gradient band: they disagree silently if any site re-derives it.
static const CGFloat kVibeBarAmplitudeOfHalfHeight = 0.75;
static inline CGFloat VibeBarVScale(CGFloat height) {
    return (height / 2) * kVibeBarAmplitudeOfHalfHeight;
}
// The band's foot, where Centered off grounds the bars.
static inline CGFloat VibeBarBaseline(CGFloat height) {
    return height / 2 - VibeBarVScale(height);
}
static inline CGRect VibeBarSeekHitBand(CGRect bounds) {
    CGFloat bottomY = round(VibeBarBaseline(bounds.size.height));
    CGFloat topY = round(bounds.size.height - VibeBarBaseline(bounds.size.height));
    return CGRectMake(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

// A few pixels over Detailed's sub-point bars and 3-Band's point-wide ones: a
// lit slice, not a blob. Pixel-snapped at use.
static const CGFloat kVibeHoverHighlightWidth = 1.5;

// The line a theme's playheadColor asks for: solid, the height of the seek
// band, pixel-snapped like the hover slice. Each view draws its own, since
// the mac's moves across the waveform and the scrubber's stays at center.
static const CGFloat kVibePlayheadLineWidth = 2;
static inline CGRect VibePlayheadLineRect(CGFloat x, CGRect band, CGFloat boundsWidth, CGFloat scale) {
    CGRect line = VibeSnappedColumnRect(x, kVibePlayheadLineWidth, boundsWidth, band.size.height, scale);
    line.origin.y = band.origin.y;
    return line;
}

NS_ASSUME_NONNULL_END
