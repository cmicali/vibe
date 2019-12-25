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
    NSPoint mouseLoc = [self convertPoint:[event locationInWindow] fromView:nil];
    if ([self mouse:mouseLoc inRect:[self bounds]]) {
        CGFloat x = mouseLoc.x - self.bounds.origin.x;
        CGFloat p = x / self.bounds.size.width;
        [self.delegate audioWaveformView:self didSeek:p];
    }
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawWaveform {

    [NSGraphicsContext.currentContext saveGraphicsState];

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

    [[NSColor whiteColor] set];

    CGContextSetLineWidth(ctx, 1.0f);

    size_t count = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    for (int i = 0; i < count ; i++) {

        MinMax m = [_waveform getMinMax:i];

        CGFloat vscale = height / 2;
        CGFloat midY = height / 2;

        CGFloat top     = midY - m.max * vscale;// max(midY - (m.max * vscale), height);
        CGFloat bottom  = midY - m.min * vscale; //min(midY - (m.min * vscale), 0);

//        auto top    = jmax (midY - cacheData->getMaxValue() * vscale - 0.3f, topY);
//        auto bottom = jmin (midY - cacheData->getMinValue() * vscale + 0.3f, bottomY);
//
//        auto r = Rectangle<float> (x, top, 2.0f, bottom - top);

        CGContextMoveToPoint(ctx, i, top);
        CGContextAddLineToPoint(ctx, i, bottom);
        CGContextStrokePath(ctx);

    }

    [NSGraphicsContext.currentContext restoreGraphicsState];

}

/*
- (void)drawWaveform {

    size_t count = self.bounds.size.width;
    CGPoint points[count];

    for (int i = 0; i < count ; i++) {
        MinMax m = [_waveform getMinMax:i];
        points[i] = CGPointMake(i, m.max);
    }

    CGMutablePathRef halfPath = CGPathCreateMutable();
    CGPathAddLines(halfPath, NULL, points, count);

    // Build the destination path
    CGMutablePathRef path = CGPathCreateMutable();

    // Transform to fit the waveform ([0,1] range) into the vertical space
    // ([halfHeight,height] range)
    double halfHeight = floor( NSHeight( self.bounds ) / 2.0 );
    CGAffineTransform xf = CGAffineTransformIdentity;
    xf = CGAffineTransformTranslate( xf, 0.0, halfHeight );
    xf = CGAffineTransformScale( xf, 1.0, halfHeight );

    // Add the transformed path to the destination path
    CGPathAddPath( path, &xf, halfPath );

    // Transform to fit the waveform ([0,1] range) into the vertical space
    // ([0,halfHeight] range), flipping the Y axis
    xf = CGAffineTransformIdentity;
    xf = CGAffineTransformTranslate( xf, 0.0, halfHeight );
    xf = CGAffineTransformScale( xf, 1.0, -halfHeight );

    // Add the transformed path to the destination path
    CGPathAddPath( path, &xf, halfPath );

    CGPathRelease( halfPath ); // clean up!

    // Now, path contains the full waveform path.

    [NSGraphicsContext.currentContext saveGraphicsState];

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

    CGContextAddPath(ctx, path);
    CGContextSetStrokeColorWithColor(ctx, [NSColor whiteColor].CGColor);
    CGContextFillPath(ctx);

    [NSGraphicsContext.currentContext restoreGraphicsState];

}
*/

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[[NSColor whiteColor] colorWithAlphaComponent:0.6] setFill];
    NSRect r = [self bounds];
    r.size.width = _progressWidth;
    NSRectFill(r);
    if (_waveform) {
        [self drawWaveform];
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
    self.needsDisplay = YES;
}

@end
