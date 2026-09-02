//
//  BasicAudioWaveformRenderer.mm
//  Vibe
//

#import "BasicAudioWaveformRenderer.h"
#import "VibeStrings.h"
#import "PlatformColor.h"

#include <cmath>

// 128 bars across the 512pt design-width waveform: a designed pitch of 4pt —
// the 3pt bar plus its gap — and the count follows the width at that pitch,
// so a resize adds or removes bars rather than spreading them apart.
static const CGFloat kBasicBarPitch = 4;
static const NSUInteger kBasicMaxBars = 1024;

#define kBasicBarWidth 3

@implementation BasicAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"basic";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_BASIC;
}

// Class-wise a Detailed subclass, but the bake paints Detailed's band-pinned
// gradient, not this style's re-aimed fade, and crops the played side
// continuously where this style's fill advances a whole block at a time. The
// scrubber's gate used to test isKindOfClass:Detailed, which let this style
// through and baked both wrong.
- (BOOL)supportsEnvelopeBake {
    return NO;
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) / kBasicBarPitch);
    return clampRange(count, (NSUInteger)2, kBasicMaxBars);
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return kBasicBarWidth;
}

- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth {
    // Fixed-width bars on a width-over-count pitch, so a gap opens between
    // them, unlike Detailed, whose bars tile the width edge to edge.
    return width * (CGFloat)index / (CGFloat)count;
}

// Discrete blocks with gaps, so the fill and the hover quantize to whole
// blocks exactly as Sonic Cirrus's bar layers do — a clip edge or a thin
// column landing inside a block read as a lit sliver of it. Both span whole
// pitch slots, edges from the barXForIndex: hook so the slot rule keeps one
// home (index count is the one-past-the-end edge, exactly the width): the
// shared bar mask clips the gap away, and stopping at the block's own right
// edge risks leaving its last device pixel unlit.
- (CGFloat)playedClipWidthForProgress:(CGFloat)progress width:(CGFloat)width {
    NSUInteger count = [self numBarsForWidth:width];
    NSUInteger boundary = (NSUInteger)VibeBlockBoundaryForProgress(progress, (NSInteger)count);
    return [self barXForIndex:boundary width:width barCount:count
                     barWidth:[self barWidthForWidth:width barCount:count]];
}

- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale {
    CGFloat width = bounds.size.width;
    NSUInteger count = [self numBarsForWidth:width];
    NSUInteger index = (NSUInteger)VibeBlockIndexForX(x, width, (NSInteger)count);
    CGFloat barWidth = [self barWidthForWidth:width barCount:count];
    // Expand to the pixel grid rather than round: overcover falls in the
    // masked gap, undercover leaves a half-lit edge pixel.
    CGFloat left = floor([self barXForIndex:index width:width barCount:count barWidth:barWidth] * scale) / scale;
    CGFloat right = ceil([self barXForIndex:index + 1 width:width barCount:count barWidth:barWidth] * scale) / scale;
    return CGRectMake(left, 0, right - left, bounds.size.height);
}

- (void)configureGradient:(CAGradientLayer *)gradient {
    // Keep the default vertical axis over the full view. Basic's four-stop
    // colors below are designed against it, not against Detailed's
    // band-pinned fade.
}

// One four-stop shape for both sides — historically the unplayed stops were
// the played stops halved, which is now the theme colors' levels doing the
// halving.
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark {
    if (self.theme.flatFill) {
        return @[color, color];
    }
    NSArray *colors = @[
            VibeColorWithScaledAlpha(color, 0.1),
            VibeColorWithScaledAlpha(color, 0.65),
            color,
            color,
    ];
    return isDark ? colors : [[colors reverseObjectEnumerator] allObjects];
}

@end
