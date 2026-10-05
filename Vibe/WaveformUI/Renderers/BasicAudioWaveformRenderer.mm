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

// The bake paints Detailed's band-pinned gradient and a continuous played
// crop; this style re-aims its fade and fills whole blocks. Never gate the
// bake on isKindOfClass:Detailed.
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

// Whole blocks, as Sonic Cirrus quantizes, or a clip edge or thin column lights
// a sliver of one. Both span whole pitch slots: the mask clips the gap, and
// stopping at the block's own edge can leave its last pixel unlit.
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

// The full-view axis, which the four stops below are designed for. Grounded,
// lowered by the band's half, so a bar's foot on the baseline is as bright as
// the midline it left.
- (void)configureGradient:(CAGradientLayer *)gradient {
    CGFloat drop = self.centered ? 0 : kVibeBarAmplitudeOfHalfHeight / 2;
    gradient.startPoint = CGPointMake(0.5, -drop);
    gradient.endPoint = CGPointMake(0.5, 1 - drop);
}

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
