//
// Created by Christopher Micali on 1/7/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "VibeStrings.h"


@implementation x2OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x2";
}

// Three separate keys, not one format string — each reaches the translator in context.
+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X2;
}

- (NSUInteger)numBars {
    return [super numBars] * 2;
}

@end

@implementation x4OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x4";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X4;
}

- (NSUInteger)numBars {
    return [super numBars] * 4;
}

@end

@implementation x8OversamplingDetailedAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"oversampling_detailed_x8";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_OVERSAMPLING_X8;
}

- (NSUInteger)numBars {
    return [super numBars] * 8;
}

@end

