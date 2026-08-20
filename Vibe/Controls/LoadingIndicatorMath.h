//
//  LoadingIndicatorMath.h
//  Vibe
//
//  The loading indicator's per-style metrics: one control, two sizes. The
//  waveform style is the numbers the control has always drawn — the hairline
//  midline, the shimmer peaking at an unplayed waveform bar's on-screen worth
//  (the renderer family's 0.5 gradient top under its 0.75 layer opacity), the
//  inert track on the unplayed baseline — so the waveform arriving over it is
//  the same brightness rather than a step down. The row style is one EQ-bar's
//  weight in the 16pt number gutter, reading at the EQ bars' alpha because
//  there are no waveform bars in a row to match.
//
//  The macOS empty-state line is the waveform style's track at rest, so it
//  reads its height and alpha from here rather than restating them.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, VibeLoadingIndicatorStyle) {
    VibeLoadingIndicatorStyleWaveform = 0,  // the hairline midline, unchanged
    VibeLoadingIndicatorStyleRow,           // a single EQ-bar-weight pill
};

typedef struct {
    CGFloat height;
    CGFloat cornerRadius;
    CGFloat bandWidth;        // the sweeping shimmer's own width
    CGFloat frontFadePoints;  // the filled head's soft front
    CGFloat trackAlpha;
    CGFloat shimmerAlpha;
    CGFloat fillAlpha;
} VibeLoadingIndicatorMetrics;

// TRAP: the waveform's 40pt minimum band width must not survive into the row
// style. On a 16pt control the 40pt floor clamps the band to the full width,
// so the sweep animates a full-width block with no visible motion. The row
// floor is small enough that the band always has room to travel.
static inline VibeLoadingIndicatorMetrics
VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyle style, CGFloat width) {
    if (style == VibeLoadingIndicatorStyleRow) {
        // height is one EQ bar's width: (16 - 4 * 1.5) / 5, from kBarGap and
        // kBarCount in EqualizerIndicatorView.m. cornerRadius makes it a pill,
        // exactly as layoutBars gives each EQ bar.
        VibeLoadingIndicatorMetrics row = {
            .height = 2,
            .cornerRadius = 1,
            .bandWidth = MAX(width * 0.35, 5),
            .frontFadePoints = 3,
            .trackAlpha = 0.30,
            .shimmerAlpha = 1.0,
            .fillAlpha = 1.0,
        };
        return row;
    }
    // A whole-point height keeps the line on device pixels at any backing
    // scale: a half-point height would centre at a half pixel and render soft,
    // which on a hairline reads as a dimmer line rather than a thinner one.
    VibeLoadingIndicatorMetrics waveform = {
        .height = 1,
        .cornerRadius = 0,
        .bandWidth = MAX(width * 0.35, 40),
        .frontFadePoints = 14,
        .trackAlpha = 0.275,
        .shimmerAlpha = 0.375,
        .fillAlpha = 0.85,
    };
    return waveform;
}
