//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformView.h"


@implementation AudioWaveformView {
    NSUInteger _progressWidth;
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

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[[NSColor whiteColor] colorWithAlphaComponent:0.6] setFill];
    NSRect r = [self bounds];
    r.size.width = _progressWidth;
    NSRectFill(r);

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


@end
