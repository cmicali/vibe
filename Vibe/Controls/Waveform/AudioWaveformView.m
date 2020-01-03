//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <PINCache/PINCache.h>
#import <Quartz/Quartz.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import "AudioWaveformView.h"
#import "AudioWaveformCache.h"
#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "DetailedAudioWaveformRenderer.h"
#import "VibeDefaultWaveformRenderer.h"


@interface AudioWaveformView () <AudioWaveformCacheDelegate>

@property (strong) AudioWaveform*       waveform;
@property (strong) AudioWaveformCache*  waveformCache;

@end

@implementation AudioWaveformView {

    CGFloat                     _progress;
    NSUInteger                  _progressWidth;

    BOOL                        _didClickInside;
    BOOL                        _seekPreviewing;
    CGFloat                     _seekPreviewLocation;

    AudioWaveformRenderer*      _currentWaveformRenderer;
    NSMutableDictionary*        _waveformRenderers;
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

    _didClickInside = NO;

    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCache.delegate = self;
    _waveformRenderers = [NSMutableDictionary new];

    [self addWaveformRenderer:[[VibeDefaultWaveformRenderer alloc] init]];
    [self addWaveformRenderer:[[DetailedAudioWaveformRenderer alloc] init]];

//    NSTrackingArea* trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds] options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways owner:self userInfo:nil];
//    [self addTrackingArea:trackingArea];

}

- (void)addWaveformRenderer:(AudioWaveformRenderer*)renderer {
    _waveformRenderers[renderer.displayName] = renderer;
}

- (NSString *)currentWaveformStyle {
    return _currentWaveformRenderer.displayName;
}

- (void)setWaveformStyle:(NSString*)name {
    if (name.length && _waveformRenderers[name]) {
        _currentWaveformRenderer = _waveformRenderers[name];
        self.needsDisplay = YES;
    }
}

- (NSArray<NSString*>*)availableWaveformStyles {
    return _waveformRenderers.allKeys;
}

/*
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
*/
- (void)mouseDown:(NSEvent *)event {
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:self.bounds]) {
        if (mouseLoc.y >= _currentWaveformRenderer.bottomY && mouseLoc.y <= _currentWaveformRenderer.topY) {
            _didClickInside = YES;
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!_didClickInside) {
        return;
    }
    _didClickInside = NO;
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:[self bounds]]) {
        CGFloat x = mouseLoc.x - self.bounds.origin.x;
        float p = (float) (x / self.bounds.size.width);
        [self.delegate audioWaveformView:self didSeek:p];
    }
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [_currentWaveformRenderer willDrawRect:self.bounds progress:_progress waveform:_waveform];
    [_currentWaveformRenderer drawRect:self.bounds progress:_progress waveform:_waveform];
    [_currentWaveformRenderer didDrawRect:self.bounds progress:_progress waveform:_waveform];
}

- (void)setProgress:(CGFloat)progress {
    NSUInteger w = (NSUInteger)(self.bounds.size.width * progress);
    _progress = progress;
    if (w != _progressWidth) {
        _progressWidth = w;
        self.needsDisplay = YES;
    }
}

- (CGFloat)progress {
    return _progress;
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    _waveform = nil;
    _progress = 0;
    _progressWidth = 0;
    if (!_currentWaveformRenderer) {
        [self setWaveformStyle:_waveformRenderers.allKeys[0]];
    }
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
