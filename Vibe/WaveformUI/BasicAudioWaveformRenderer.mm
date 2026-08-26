//
//  BasicAudioWaveformRenderer.mm
//  Vibe
//

#import "BasicAudioWaveformRenderer.h"
#import "VibeStrings.h"

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

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) / kBasicBarPitch);
    return MIN(MAX(count, (NSUInteger)2), kBasicMaxBars);
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return kBasicBarWidth;
}

- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth {
    // Fixed-width bars on a width-over-count pitch, so a gap opens between
    // them, unlike Detailed, whose bars tile the width edge to edge.
    return width * (CGFloat)index / (CGFloat)count;
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
            VibeColorAtRampFraction(color, 0.1),
            VibeColorAtRampFraction(color, 0.65),
            color,
            color,
    ];
    return isDark ? colors : [[colors reverseObjectEnumerator] allObjects];
}

@end
