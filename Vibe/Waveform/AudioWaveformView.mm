//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Quartz/Quartz.h>
#import "AudioWaveformView.h"
#import "AudioTrack.h"
#import "DetailedAudioWaveformRenderer.h"
#import "VibeDefaultWaveformRenderer.h"
#import "BasicAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "NSView+DarkMode.h"

@interface AudioWaveformView () <AudioWaveformCacheDelegate>

@property (nonatomic) AudioWaveform*    waveform;
@property (strong) AudioWaveformCache*  waveformCache;

@end

@implementation AudioWaveformView {
    CGFloat                     _progress;
    NSUInteger                  _progressTracker;
    NSUInteger                  _numProgressSteps;
    BOOL                        _didClickInside;
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

    self.wantsLayer = YES;
    self.layer = [[CALayer alloc] init];
    self.layerUsesCoreImageFilters = YES;

    _progress = 0;
    _progressTracker = 0;
    _numProgressSteps = 256;
    _didClickInside = NO;

    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCache.delegate = self;
    _waveformRenderers = [NSMutableDictionary new];

    [self addWaveformRenderer:BasicAudioWaveformRenderer.class];
    [self addWaveformRenderer:VibeDefaultWaveformRenderer.class];
    [self addWaveformRenderer:DetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x2OversamplingDetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x4OversamplingDetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x8OversamplingDetailedAudioWaveformRenderer.class];

}

- (void)addWaveformRenderer:(id)renderer {
    _waveformRenderers[[renderer displayName]] = renderer;
}

- (NSString *)currentWaveformStyle {
    return [_currentWaveformRenderer.class displayName];
}

- (void)setWaveformStyle:(NSString*)name {
    if (name.length && _waveformRenderers[name]) {
        _currentWaveformRenderer = [[_waveformRenderers[name] alloc] initWithLayer:self.layer bounds:self.bounds isDark:self.isDark];
        [self drawWaveform];
        [self updateRendererProgress];
    }
}

- (void)drawWaveform {
    [_currentWaveformRenderer willUpdateWaveform:self.bounds progress:self.progress waveform:self.waveform];
    [_currentWaveformRenderer updateWaveform:self.bounds progress:self.progress waveform:self.waveform];
    [_currentWaveformRenderer didUpdateWaveform:self.bounds progress:self.progress waveform:self.waveform];
}

- (void)updateRendererProgress {
    [CATransaction begin];
    CATransaction.animationDuration = 0;
    [_currentWaveformRenderer updateProgress:_progress waveform:self.waveform];
    [CATransaction commit];
    _currentWaveformRenderer.progress = _progress;
}

- (NSArray<NSString*>*)availableWaveformStyles {
    return _waveformRenderers.allKeys;
}

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

- (void)setProgress:(CGFloat)progress {
    NSUInteger p = static_cast<NSUInteger>(progress * _numProgressSteps);
    if (_progressTracker != p) {
        _progressTracker = p;
        _progress = progress;
        [self updateRendererProgress];
    }
}


- (CGFloat)progress {
    return _progress;
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    _waveform = nil;
    if (!_currentWaveformRenderer) {
        [self setWaveformStyle:_waveformRenderers.allKeys[0]];
    }
    self.progress = 0;
    [self drawWaveform];
    [_waveformCache loadWaveformForTrack:track];
}

- (void)audioWaveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (_waveform != waveform) {
        _waveform = waveform;
    }
    [self drawWaveform];
}

- (void)updateAppearance {
    if (_currentWaveformRenderer) {
        BOOL isDark = self.isDark;
        if (_currentWaveformRenderer.isDark != isDark) {
            [_currentWaveformRenderer updateColors:isDark];
            [self updateRendererProgress];
        }
    }
}

@end
