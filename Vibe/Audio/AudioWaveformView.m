//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <PINCache/PINCache.h>
#import <Quartz/Quartz.h>
#import "AudioWaveformView.h"
#import "AudioWaveform.h"
#import "AudioTrack.h"
#import "NSURL+Hash.h"


@implementation AudioWaveformView {
    NSUInteger _progressWidth;
    AudioWaveform *_waveform;
    PINCache *_waveformCache;
    dispatch_queue_t _loaderQueue;
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
    _loaderQueue = dispatch_queue_create("AudioWaveformViewLoader", DISPATCH_QUEUE_SERIAL);
    _waveformCache = [[PINCache alloc] initWithName:@"waveform_cache"];
    _waveformCache.diskCache.byteLimit = 64 * 1024 * 1024; // 64mb disk cache limit
    _waveformCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
}

-(void)dealloc {

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

        int step = 1;

        for (int i = 0; i < count ; i+=step) {

            CGFloat colorFactor = (i%2?1:0.5);
            if (i >= _progressWidth+step) {
                [[[NSColor controlTextColor] colorWithAlphaComponent:0.50 * colorFactor] set];
            }
            else {
                [[[NSColor controlTextColor] colorWithAlphaComponent:0.95 * colorFactor] set];
            }

            MinMax m = [_waveform getMinMax:i];

            CGFloat top     = round(midY - m.max * vscale);
            CGFloat bottom  = round(midY - m.min * vscale);

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

- (void)audioWaveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (_waveform != waveform) {
        _waveform = waveform;
    }
    if (percentLoaded == 1.0) {
        [_waveformCache setObject:waveform forKey:waveform.fileHash];
    }
    self.needsDisplay = YES;
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    [_waveform cancel];
    _waveform = nil;
    _progressWidth = 0;
    self.needsDisplay = YES;
    dispatch_async(_loaderQueue, ^{
        NSString *hash = [track.url sha1HashOfFile];
        __block AudioWaveform *w = [self->_waveformCache objectForKey:hash];
        if (w) {
            w.fileHash = hash;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self audioWaveform:w didLoadData:1];
            });
        }
        else {
            w = [[AudioWaveform alloc] init];
            w.fileHash = hash;
            w.delegate = self;
            self->_waveform = w;
            [w load:track.url.path];
        }
    });
}

@end
