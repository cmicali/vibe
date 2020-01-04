//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"
#import "AudioWaveform.h"

@implementation DetailedAudioWaveformRenderer

- (NSString *)displayName {
    return @"Detailed";
}

+ (NSGradient*)gradient {
    static NSGradient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.75],
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.25],
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.0],
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.0]
        ]];
    });
    return instance;
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat progressWidth = width * progress;
    size_t count = (size_t)width;

    CGFloat vscale = (height / 2) * 0.70;
    CGFloat midY = height / 2;

    [[[NSColor controlTextColor] colorWithAlphaComponent:0.95] set];

    CGContextSetLineWidth(ctx, 0.25f);
//    CGContextSetAllowsAntialiasing(ctx, NO);

    CGFloat step = 0.25;

    for (CGFloat i = 0; i < count ; i+=step) {

        CGFloat colorFactor = 1; //(i%2?1:0.5);

        BOOL isPastPlayhead = i >= (progressWidth + step);
        if (isPastPlayhead) {
            [[[NSColor controlTextColor] colorWithAlphaComponent:0.35 * colorFactor] set];
        }
        else {
            [[[NSColor controlTextColor] colorWithAlphaComponent:0.95 * colorFactor] set];
        }

        AudioWaveformCacheChunk* m = [waveform chunkAtIndex:(NSUInteger)(i / count * waveform.count)];
        if (!m) m = [AudioWaveform emptyChunk];

        CGFloat top     = round(midY - m->min * vscale);
        CGFloat bottom  = round(midY - m->max * vscale);

        if (top - bottom == 0) {
            top += 0.5;
            bottom -= 0.5;
        }

        [self updateWaveformBounds:top bottom:bottom];

        CGContextMoveToPoint(ctx, i+0.5 , top + 0.5);
        CGContextAddLineToPoint(ctx, i+0.5 , bottom + 0.5);
        CGContextStrokePath(ctx);

    }

    NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationSourceAtop;
    NSGradient *g = [DetailedAudioWaveformRenderer gradient];
    [g drawInRect:bounds angle:90];

}

@end
