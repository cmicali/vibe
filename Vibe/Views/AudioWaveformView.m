//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <PINCache/PINCache.h>
#import <Quartz/Quartz.h>
#import "AudioWaveformView.h"
#import "AudioWaveformCache.h"
#import "AudioTrack.h"
#import "NSURL+Hash.h"


@interface AudioWaveformView () <AudioWaveformCacheDelegate>

@property (strong) AudioWaveform*       waveform;
@property (strong) AudioWaveformCache*  waveformCache;

@end

@implementation AudioWaveformView {
    NSUInteger          _progressWidth;
    BOOL                _seekPreviewing;
    CGFloat             _seekPreviewLocation;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup  {
    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCache.delegate = self;
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
                                                    initWithRect:[self bounds]
                                                         options:NSTrackingMouseEnteredAndExited |
                                                                 NSTrackingMouseMoved |
                                                                 NSTrackingActiveAlways
                                                           owner:self userInfo:nil];
    [self addTrackingArea:trackingArea];

}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:[self bounds]]) {
//        _seekPreviewing = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    _seekPreviewing = NO;
}

- (void)mouseMoved:(NSEvent *)event {
    if (!_seekPreviewing)
        return;
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:CGRectInset(self.bounds, 0, 10)]) {
        CGFloat x = mouseLoc.x - self.bounds.origin.x;
        CGFloat p = round(x);
        if (_seekPreviewLocation != p) {
            _seekPreviewLocation = p;
            self.needsDisplay = YES;
        }
    }
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

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    if (_waveform) {

        [NSGraphicsContext.currentContext saveGraphicsState];

        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

        size_t count = (size_t) self.bounds.size.width;
        CGFloat height = self.bounds.size.height;

        CGFloat vscale = (height / 2) * 0.70;
        CGFloat midY = height / 2;

        [[[NSColor controlTextColor] colorWithAlphaComponent:0.95] set];

        CGContextSetLineWidth(ctx, 1.0f);

        NSUInteger step = 1;

        for (NSUInteger i = 0; i < count ; i+=step) {

            CGFloat colorFactor = (i%2?1:0.5);

            BOOL isPastPlayhead = (i >= _progressWidth+step);
            BOOL isSeekPreviewPastPlayhead = (_seekPreviewLocation >= _progressWidth+step);
            if (isPastPlayhead) {
                [[[NSColor controlTextColor] colorWithAlphaComponent:0.50 * colorFactor] set];
                if (_seekPreviewing && isSeekPreviewPastPlayhead && i < _seekPreviewLocation) {
                    [[[NSColor controlTextColor] colorWithAlphaComponent:0.65 * colorFactor] set];
                }
                else {
                    [[[NSColor controlTextColor] colorWithAlphaComponent:0.50 * colorFactor] set];
                }
            }
            else {
                [[[NSColor controlTextColor] colorWithAlphaComponent:0.95 * colorFactor] set];
            }
//            }

            AudioWaveformCacheChunk* m = [_waveform chunkAtIndex:i];

            CGFloat top     = round(midY - m->max * vscale);
            CGFloat bottom  = round(midY - m->min * vscale);

            CGContextMoveToPoint(ctx, i + 0.5, top + 0.5);
            CGContextAddLineToPoint(ctx, i + 0.5, bottom + 0.5);
            CGContextStrokePath(ctx);

        }

        NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationSourceAtop;
        NSGradient *g = [AudioWaveformView gradient];
        [g drawInRect:self.bounds angle:90];

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

- (void)loadWaveformForTrack:(AudioTrack *)track {
    _waveform = nil;
    _progressWidth = 0;
    self.needsDisplay = YES;
    [_waveformCache loadWaveformForTrack:track];
}

- (void)audioWaveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (_waveform != waveform) {
        _waveform = waveform;
    }
    self.needsDisplay = YES;
}

@end
