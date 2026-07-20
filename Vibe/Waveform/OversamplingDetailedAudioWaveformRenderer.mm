//
// Created by Christopher Micali on 1/7/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "OversamplingDetailedAudioWaveformRenderer.h"


@implementation x2OversamplingDetailedAudioWaveformRenderer

+ (NSString *)displayName {
    return @"Oversampling Detailed x2";
}

- (NSUInteger)numBars {
    return [super numBars] * 2;
}

@end

@implementation x4OversamplingDetailedAudioWaveformRenderer

+ (NSString *)displayName {
    return @"Oversampling Detailed x4";
}

- (NSUInteger)numBars {
    return [super numBars] * 4;
}

@end

@implementation x8OversamplingDetailedAudioWaveformRenderer

+ (NSString *)displayName {
    return @"Oversampling Detailed x8";
}

- (NSUInteger)numBars {
    return [super numBars] * 8;
}

@end

