//
//  OversamplingDetailedAudioWaveformRenderer.mm
//  Vibe
//

#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "VibeStrings.h"

// Fixed counts at every width: the sub-pixel overlap is the look. 1,024 is
// Detailed's count at its 512pt design width.
static const NSUInteger kOversamplingBaseBars = 1024;

@implementation x2OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x2";
}

// Three keys, not one format string, so each reaches the translator in context.
+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X2;
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 2;
}

@end

@implementation x4OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x4";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X4;
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 4;
}

@end

@implementation x8OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x8";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X8;
}

- (NSUInteger)numBarsForWidth:(CGFloat)width {
    return kOversamplingBaseBars * 8;
}

@end

