//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformView.h"
#import "AudioWaveform.h"
#import "DetailedAudioWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#import "BasicAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "NSView+DarkMode.h"
#import "AppSettings.h"

@interface AudioWaveformView ()

// Strong reference to the wrapper — it owns the underlying C++ AudioWaveform,
// so holding it keeps the raw pointer handed to renderers valid.
@property (nonatomic, strong, nullable) CodableAudioWaveform* waveform;

@end

@implementation AudioWaveformView {
    CGFloat                     _progress;
    NSUInteger                  _progressTracker;
    NSUInteger                  _numProgressSteps;
    BOOL                        _didClickInside;
    AudioWaveformRenderer*      _currentWaveformRenderer;
    // Renderer classes keyed by their display name; instantiated on selection.
    NSMutableDictionary<NSString *, Class>* _waveformRenderers;
    CAGradientLayer*            _loadingLayer;
    CALayer*                    _placeholderLayer;
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

    // Layer-hosting contract: assign the layer BEFORE setting wantsLayer,
    // or AppKit first creates its own backing layer and the view is
    // layer-backed, not layer-hosting.
    self.layer = [[CALayer alloc] init];
    self.wantsLayer = YES;

    _progress = 0;
    _progressTracker = 0;
    _numProgressSteps = 256;
    _didClickInside = NO;

    _waveformRenderers = [NSMutableDictionary new];

    [self addWaveformRenderer:BasicAudioWaveformRenderer.class];
    [self addWaveformRenderer:SonicCirrusWaveformRenderer.class];
    [self addWaveformRenderer:DetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x2OversamplingDetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x4OversamplingDetailedAudioWaveformRenderer.class];
    [self addWaveformRenderer:x8OversamplingDetailedAudioWaveformRenderer.class];

}

- (void)addWaveformRenderer:(Class)renderer {
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
    [_currentWaveformRenderer updateWaveform:self.bounds progress:self.progress waveform:self.waveform.waveform];
}

- (void)updateRendererProgress {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_currentWaveformRenderer updateProgress:_progress waveform:self.waveform.waveform];
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
        NSRect band = [_currentWaveformRenderer seekHitBandForBounds:self.bounds];
        if (mouseLoc.y >= NSMinY(band) && mouseLoc.y <= NSMaxY(band)) {
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
    // Store unconditionally — the bucket tracker below only gates repaints;
    // gating the assignment too would leave the getter up to 1/256 stale.
    _progress = progress;
    NSUInteger p = static_cast<NSUInteger>(progress * _numProgressSteps);
    if (_progressTracker != p) {
        _progressTracker = p;
        [self updateRendererProgress];
    }
}


- (CGFloat)progress {
    return _progress;
}

- (void)prepareForWaveformLoad {
    [self hideLoadingIndicator];
    [self hideEmptyPlaceholder];
    _waveform = nil;
    if (!_currentWaveformRenderer) {
        // Prefer the persisted style, then the app default; allKeys[0] is a
        // last resort only (NSMutableDictionary key order is unspecified, so
        // it would otherwise pick an arbitrary renderer run to run).
        NSString *style = [[AppSettings sharedInstance] waveformStyle];
        if (!style.length || !_waveformRenderers[style]) {
            style = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
        }
        if (!_waveformRenderers[style]) {
            style = _waveformRenderers.allKeys.firstObject;
        }
        [self setWaveformStyle:style];
    }
    self.progress = 0;
    [self drawWaveform];
}

- (void)showLoadingIndicator {
    if (_loadingLayer) {
        return;
    }
    [self hideEmptyPlaceholder];
    // Collapse any previous track's waveform so the shimmer stands alone.
    _waveform = nil;
    self.progress = 0;
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CAGradientLayer *shimmer = [CAGradientLayer layer];
    shimmer.contentsScale = self.window ? self.window.backingScaleFactor : 2.0;
    shimmer.startPoint = CGPointMake(0, 0.5);
    shimmer.endPoint = CGPointMake(1, 0.5);
    // Follows the appearance like the renderer palettes do — a fixed white
    // band is near-invisible on a light background.
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    shimmer.colors = @[
            (id)[base colorWithAlphaComponent:0].CGColor,
            (id)[base colorWithAlphaComponent:0.55].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
    [self.layer addSublayer:shimmer];
    _loadingLayer = shimmer;

    // Frame + sweep depend on the current bounds; a helper keeps them in sync
    // when the window resizes (or small/large layout toggles) mid-load.
    [self layoutLoadingLayer];
}

// Position the shimmer band and (re)install its sweep for the current bounds.
- (void)layoutLoadingLayer {
    if (!_loadingLayer) {
        return;
    }
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2;
    CGFloat bandWidth = MAX(width * 0.35, 40);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _loadingLayer.frame = CGRectMake(0, midY - 1, bandWidth, 2);
    [CATransaction commit];

    [_loadingLayer removeAnimationForKey:@"sweep"];
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweep.fromValue = @(-bandWidth / 2);
    sweep.toValue = @(width + bandWidth / 2);
    sweep.duration = 1.2;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_loadingLayer addAnimation:sweep forKey:@"sweep"];
}

- (void)hideLoadingIndicator {
    [_loadingLayer removeAllAnimations];
    [_loadingLayer removeFromSuperlayer];
    _loadingLayer = nil;
}

- (void)showEmptyPlaceholder {
    if (_placeholderLayer) {
        return;
    }
    [self hideLoadingIndicator];
    _waveform = nil;
    self.progress = 0;
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CALayer *line = [CALayer layer];
    line.contentsScale = self.window ? self.window.backingScaleFactor : 2.0;
    [self.layer addSublayer:line];
    _placeholderLayer = line;

    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

// Same 2pt midline band the shimmer sweeps, but full-width and static.
- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - 1, self.bounds.size.width, 2);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    // Half the shimmer's 0.55 peak, so the empty state recedes.
    _placeholderLayer.backgroundColor = [base colorWithAlphaComponent:0.275].CGColor;
}

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    _waveform = waveform;
    [self drawWaveform];
}

- (void)setFrameSize:(NSSize)newSize {
    BOOL sizeChanged = !NSEqualSizes(newSize, self.frame.size);
    [super setFrameSize:newSize];
    if (sizeChanged && _waveform) {
        [self drawWaveform];
    }
    if (sizeChanged && _loadingLayer) {
        // Keep the shimmer centered and spanning the new width mid-load.
        [self layoutLoadingLayer];
    }
    if (sizeChanged && _placeholderLayer) {
        [self layoutPlaceholderLayer];
    }
}

static void applyContentsScale(CALayer *layer, CGFloat scale) {
    if (!layer) return;
    layer.contentsScale = scale;
    applyContentsScale(layer.mask, scale);
    for (CALayer *sublayer in layer.sublayers) {
        applyContentsScale(sublayer, scale);
    }
}

// Keep the manually-created layer tree (renderer sublayers, masks, gradients)
// at the window's backing scale — the root layer is layer-hosted, so AppKit
// doesn't manage contentsScale for us.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
    applyContentsScale(self.layer, scale);
}

// Fires when the system switches light/dark (with "System default" appearance
// the window follows the OS). Without this, the cached renderer colors go
// stale until a manual View→Appearance toggle.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateAppearance];
}

- (void)updateAppearance {
    if (_currentWaveformRenderer) {
        BOOL isDark = self.isDark;
        if (_currentWaveformRenderer.isDark != isDark) {
            [_currentWaveformRenderer updateColors:isDark];
            [self updateRendererProgress];
        }
    }
    if (_placeholderLayer) {
        [self updatePlaceholderColor];
    }
}

@end
