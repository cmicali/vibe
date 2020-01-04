//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"
#import "AudioWaveform.h"

@implementation AudioWaveformRenderer

- (instancetype)initWithLayer:(CALayer*)layer bounds:(CGRect)bounds {
    self = [super init];
    if (self) {
    }
    return self;
}

+ (NSString *)displayName {
    return nil;
}

- (void)updateWaveformBounds:(CGFloat)top bottom:(CGFloat)bottom {
    if (top > self.topY) {
        self.topY = top;
    }
    if (bottom < self.bottomY) {
        self.bottomY = bottom;
    }
}

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    self.bottomY = bounds.size.height/2 - (bounds.size.height/2 * .5);
    self.topY = bounds.size.height/2 + (bounds.size.height/2 * .5);
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
}

@end
