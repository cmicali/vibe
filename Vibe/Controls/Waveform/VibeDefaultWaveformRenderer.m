//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "VibeDefaultWaveformRenderer.h"


@implementation VibeDefaultWaveformRenderer

- (NSString *)displayName {
    return @"Vibe Default";
}

+ (CGGradientRef)gradient {
    static CGGradientRef gradient;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGFloat locations[2] = { 0.0, 1.0 };
        CGFloat colors[8] = {
                1, 0.20, 0, 1,
                1, 0.45, 0, 1,
        };
        gradient = CGGradientCreateWithColorComponents(colorSpace, colors, locations, 2);
        CGColorSpaceRelease(colorSpace);
    });
    return gradient;
}

- (void)drawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat progressWidth = width * progress;
    size_t count = (size_t)width;

    CGFloat vscale = height * 0.70;// (height / 2) * 0.70;
    CGFloat midY = height / 2;


    CGColorRef playedColor = CGColorCreateGenericRGB(1, 0.45, 0, 1);
    CGColorRef unplayedColor = CGColorCreateGenericRGB(1, 1, 1, 1);

//    CGContextSetLineWidth(ctx, 0.25f);
//    CGContextSetAllowsAntialiasing(ctx, NO);

    CGFloat step = 4;

    for (CGFloat i = 0; i < count ; i += step) {

        BOOL isPastPlayhead = i >= (progressWidth + step);

        AudioWaveformCacheChunk* m = [waveform chunkAtIndex:(NSUInteger)(i / count * waveform.count)];
        if (!m) m = [AudioWaveform emptyChunk];

        CGFloat top     = fabs(m->max - m->min)/2 * vscale;
        CGFloat bottom  = 0;

        [self updateWaveformBounds:top bottom:bottom];

        if (isPastPlayhead) {
//            top *= vscale;
            CGContextSetFillColorWithColor(ctx, unplayedColor);
            CGContextFillRect(ctx, CGRectMake(i+0.5, bottom, 2, top));
        }
        else {
            CGContextSetFillColorWithColor(ctx, playedColor);
            CGContextFillRect(ctx, CGRectMake(i + 0.5, bottom, 2, top));
        }
//            top *= vscale;
            CGContextAddRect(ctx, CGRectMake(i+0.5, bottom, 2, top));
//            CGContextDrawLinearGradient(ctx, [VibeDefaultWaveformRenderer gradient], CGPointMake(0, 0), CGPointMake(0, 1), 0);
//        }


//        CGContextMoveToPoint(ctx, i+0.5 , top + 0.5);
//        CGContextAddLineToPoint(ctx, i+0.5 , bottom + 0.5);
//        CGContextStrokePath(ctx);

    }

//    CGContextClip(ctx);
//    CGContextDrawLinearGradient(ctx, [VibeDefaultWaveformRenderer gradient], CGPointMake(0, 0), CGPointMake(0, 90), 0);

//
//    NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationSourceAtop;
//    NSGradient *g = [DetailedAudioWaveformRenderer gradient];
//    [g drawInRect:bounds angle:90];

}
//- (void) drawRect:(CGRect)rect
//{
//    // Create a gradient from white to red
//    CGFloat colors [] = {
//            1.0, 1.0, 1.0, 1.0,
//            1.0, 0.0, 0.0, 1.0
//    };

//    CGColorSpaceRef baseSpace = CGColorSpaceCreateDeviceRGB();
//    CGGradientRef gradient = CGGradientCreateWithColorComponents(baseSpace, colors, NULL, 2);
//    CGColorSpaceRelease(baseSpace), baseSpace = NULL;
//
//    CGContextRef context = UIGraphicsGetCurrentContext();
//
//    CGContextSaveGState(context);
//    CGContextAddEllipseInRect(context, rect);
//    CGContextClip(context);
//
//    CGPoint startPoint = CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect));
//    CGPoint endPoint = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));
//
//    CGContextDrawLinearGradient(context, gradient, startPoint, endPoint, 0);
//    CGGradientRelease(gradient), gradient = NULL;
//
//    CGContextRestoreGState(context);
//
//    CGContextAddEllipseInRect(context, rect);
//    CGContextDrawPath(context, kCGPathStroke);

@end
