//
//  OversamplingDetailedWaveformRenderer.mm
//  Vibe
//

#import "OversamplingDetailedWaveformRenderer.h"

// Fixed counts at every width: the sub-pixel overlap is the look. 1,024 is
// Detailed's count at its 512pt design width.
static const NSUInteger kOversamplingBaseBars = 1024;

@implementation x2OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x2";
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 2;
}

@end

@implementation x4OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x4";
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 4;
}

@end

@implementation x8OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x8";
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 8;
}

@end

