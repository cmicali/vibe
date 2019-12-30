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

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    if (_waveform) {

        [NSGraphicsContext.currentContext saveGraphicsState];

        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

        size_t count = (size_t) self.bounds.size.width;
        CGFloat height = self.bounds.size.height;

        bool switchedColor = NO;

        CGFloat vscale = (height / 2) * 0.70;
        CGFloat midY = height / 2;

        [[[NSColor controlTextColor] colorWithAlphaComponent:0.85] set];

        CGContextSetLineWidth(ctx, 1.0f);

        int step = 2;
        for (int i = 0; i < count ; i+=step) {

            if (!switchedColor && i >= _progressWidth+step) {
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
    WEAK_SELF dispatch_async(_loaderQueue, ^{
        NSString *hash = [track.url sha1HashOfFile];
        __block AudioWaveform *w = [weakSelf->_waveformCache objectForKey:hash];
        if (w) {
            w.fileHash = hash;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf audioWaveform:w didLoadData:1];
            });
        }
        else {
            w = [[AudioWaveform alloc] init];
            w.fileHash = hash;
            w.delegate = self;
            weakSelf->_waveform = w;
            [w load:track.url.path];
        }
    });
}

@end
