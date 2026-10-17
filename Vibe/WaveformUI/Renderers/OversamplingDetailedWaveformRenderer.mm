//
//  OversamplingDetailedWaveformRenderer.mm
//  Vibe
//

#import "OversamplingDetailedWaveformRenderer.h"

// Twice, four and eight times Detailed's columns: the sub-pixel overlap is
// the look, the same at every width.
@implementation x2OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x2";
}

- (double)columnsPerPoint {
    return 4;
}

@end

@implementation x4OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x4";
}

- (double)columnsPerPoint {
    return 8;
}

@end

@implementation x8OversamplingDetailedWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x8";
}

- (double)columnsPerPoint {
    return 16;
}

@end
