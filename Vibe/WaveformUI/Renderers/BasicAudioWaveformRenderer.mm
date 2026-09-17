//
//  BasicAudioWaveformRenderer.mm
//  Vibe
//

#import "BasicAudioWaveformRenderer.h"
#import "VibeStrings.h"
#import "PlatformColor.h"

#include <cmath>

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
    return [self blockBarCountForWidth:width];
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return [self scaledBarWidth:kBasicBarWidth / MAX((CGFloat)1, self.barDensity)
                         pitch:width / count];
}

// Discrete blocks with gaps, so the fill and the hover quantize to whole
// blocks exactly as Sonic Cirrus's bar layers do — a clip edge or a thin
// column landing inside a block read as a lit sliver of it. Both span whole
// pitch slots (index count is the one-past-the-end edge, exactly the width): the
// shared bar mask clips the gap away, and stopping at the block's own right
// edge risks leaving its last device pixel unlit.
- (CGFloat)playedClipWidthForProgress:(CGFloat)progress width:(CGFloat)width {
    NSUInteger count = [self numBarsForWidth:width];
    NSUInteger boundary = (NSUInteger)VibeBlockBoundaryForProgress(progress, (NSInteger)count);
    return width * (CGFloat)boundary / (CGFloat)count;
}

- (CGRect)hoverColumnRectForX:(CGFloat)x bounds:(CGRect)bounds scale:(CGFloat)scale {
    CGFloat width = bounds.size.width;
    NSUInteger count = [self numBarsForWidth:width];
    NSUInteger index = (NSUInteger)VibeBlockIndexForX(x, width, (NSInteger)count);
    // Expand to the pixel grid rather than round: overcover falls in the
    // masked gap, undercover leaves a half-lit edge pixel.
    CGFloat left = floor(width * (CGFloat)index / (CGFloat)count * scale) / scale;
    CGFloat right = ceil(width * (CGFloat)(index + 1) / (CGFloat)count * scale) / scale;
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
