//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformView.h"
#import "AudioWaveform.h"


@implementation AudioWaveformView {
    NSUInteger _progressWidth;
    AudioWaveform *_waveform;
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:[self bounds]]) {
        CGFloat x = mouseLoc.x - self.bounds.origin.x;
        CGFloat p = x / self.bounds.size.width;
        [self.delegate audioWaveformView:self didSeek:p];
    }
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (_waveform) {
        [NSGraphicsContext.currentContext saveGraphicsState];

        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

        size_t count = self.bounds.size.width;
        CGFloat height = self.bounds.size.height;

        bool switchedColor = NO;

        CGFloat vscale = (height / 2) * 0.70;
        CGFloat midY = height / 2;

        [[[NSColor controlTextColor] colorWithAlphaComponent:0.85] set];

        CGContextSetShouldAntialias(ctx, NO);

//        CGContextScaleCTM(ctx, 0.5, 0.5); // Back out the default scale
//        CGContextTranslateCTM(ctx, 0.5, 0.5); // Offset from edges of pixels to centers of pixels

        CGContextSetLineWidth(ctx, 0.5f);

        for (int i = 0; i < count ; i++) {

            if (!switchedColor && i >= _progressWidth) {
                [[[NSColor controlTextColor] colorWithAlphaComponent:0.50] set];
                switchedColor = YES;
            }

            MinMax m = [_waveform getMinMax:i];

            CGFloat top     = midY - m.max * vscale;
            CGFloat bottom  = midY - m.min * vscale;

            CGContextMoveToPoint(ctx, i + 0.5, top);
            CGContextAddLineToPoint(ctx, i + 0.5, bottom);
            CGContextStrokePath(ctx);

        }

        [NSGraphicsContext.currentContext restoreGraphicsState];
    }
}

- (void)setProgress:(CGFloat)progress {
    NSUInteger w = (NSUInteger)(self.bounds.size.width * progress);
    if (w != _progressWidth) {
        _progressWidth = w;
        self.needsDisplay = YES;
    }
}

- (CGFloat)progress {
    return _progressWidth/self.bounds.size.width;
}

- (void)setWaveform:(AudioWaveform *)waveform {
    _waveform = waveform;
    [self setProgress:0];
    self.needsDisplay = YES;
}

@end
