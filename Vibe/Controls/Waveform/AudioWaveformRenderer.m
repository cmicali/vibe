//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"
#import "AudioWaveform.h"

@implementation AudioWaveformRenderer

- (NSString *)displayName {
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

- (void)willDrawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    self.bottomY = bounds.size.height/2 - (bounds.size.height/2 * .5);
    self.topY = bounds.size.height/2 + (bounds.size.height/2 * .5);
    [NSGraphicsContext.currentContext saveGraphicsState];
}

- (void)drawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)didDrawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    [NSGraphicsContext.currentContext restoreGraphicsState];
}

@end
