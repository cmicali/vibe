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

// A strong reference to the wrapper. It owns the underlying C++ AudioWaveform,
// so holding it keeps the raw pointer handed to the renderers valid.
@property (nonatomic, strong, nullable) CodableAudioWaveform* waveform;

@end

@implementation AudioWaveformView {
    CGFloat                     _progress;
    NSUInteger                  _progressTracker;
    // The convert sweep's front: bars left of it have already been dipped.
    double                      _convertSweepFraction;
    BOOL                        _didClickInside;
    AudioWaveformRenderer*      _currentWaveformRenderer;
    // The renderer classes, keyed by styleIdentifier and instantiated on
    // selection.
    NSMutableDictionary<NSString *, Class>* _waveformRenderers;
    CAGradientLayer*            _loadingLayer;
    CALayer*                    _placeholderLayer;
    NSTrackingArea*             _hoverTrackingArea;
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

    // The layer-hosting contract: assign the layer before setting wantsLayer,
    // or AppKit first creates its own backing layer and the view ends up
    // layer-backed rather than layer-hosting.
    self.layer = [[CALayer alloc] init];
    self.wantsLayer = YES;

    _progress = 0;
    _progressTracker = 0;
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
    _waveformRenderers[[renderer styleIdentifier]] = renderer;
}

- (NSString *)currentWaveformStyle {
    return [_currentWaveformRenderer.class styleIdentifier];
}

- (void)setWaveformStyle:(NSString*)identifier {
    Class renderer = identifier.length ? _waveformRenderers[identifier] : nil;
    if (!renderer) {
        // Unknown identifier (hand-edited default, or a style dropped in a
        // later version): fall back rather than leaving a blank waveform.
        renderer = _waveformRenderers[SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT];
        if (!renderer) {
            return;
        }
    }
    _currentWaveformRenderer = [[renderer alloc] initWithLayer:self.layer bounds:self.bounds isDark:self.isDark];
    [self drawWaveform];
    [self updateRendererProgress];
}

- (NSString *)displayNameForStyle:(NSString *)identifier {
    return [_waveformRenderers[identifier] displayName] ?: identifier;
}

- (void)drawWaveform {
    [_currentWaveformRenderer updateWaveform:self.bounds progress:self.progress waveform:self.waveform.waveform];
}

- (void)updateRendererProgress {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_currentWaveformRenderer updateProgress:_progress waveform:self.waveform.waveform];
    [CATransaction commit];
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

#pragma mark - Hover scrubbing affordance

// Hovering lights the waveform's own column under the cursor to full
// brightness. The renderer does the drawing, since each style knows how its
// bars are built, and nothing is overlaid on top. Click-to-seek is untouched.

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverTrackingArea) {
        [self removeTrackingArea:_hoverTrackingArea];
    }
    // ActiveAlways, to match the window's hover-reveal chrome: the borderless
    // window's controls track the cursor whatever the key state.
    _hoverTrackingArea = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                         NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved
                   owner:self userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [self updateHoverForEvent:event];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateHoverForEvent:event];
}

- (void)mouseExited:(NSEvent *)event {
    [self hideHoverIndicator];
}

- (void)updateHoverForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // No waveform means nothing to light, and nothing seekable. The empty,
    // loading and parked states all land here.
    if (!_waveform || !NSPointInRect(p, self.bounds)) {
        [self hideHoverIndicator];
        return;
    }
    [_currentWaveformRenderer setHoverHighlightX:p.x];
}

- (void)hideHoverIndicator {
    [_currentWaveformRenderer setHoverHighlightX:-1];
}

- (void)setProgress:(CGFloat)progress {
    // Store it unconditionally. The bucket tracker below gates repaints alone,
    // and gating the assignment too would leave the getter stale between them.
    _progress = progress;
    // Repaint whenever the playhead crosses a device pixel. The gate must be
    // width-based rather than a fixed fraction of the track: a
    // duration-proportional step stalls the played-unplayed boundary for many
    // seconds on an hour-long mix, and swallows sub-step seeks entirely.
    CGFloat scale = VibeBackingScaleForWindow(self.window);
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)(self.bounds.size.width * scale));
    NSUInteger p = static_cast<NSUInteger>(progress * steps);
    if (_progressTracker != p) {
        _progressTracker = p;
        [self updateRendererProgress];
    }
}


- (CGFloat)progress {
    return _progress;
}

- (double)convertSweepFraction {
    return _convertSweepFraction;
}

// Only the span newly crossed since the last set is dipped: bars behind the
// front are already easing home and must not be re-zeroed.
- (void)setConvertSweepFraction:(double)fraction {
    if (fraction <= _convertSweepFraction) {
        _convertSweepFraction = MAX(0.0, fraction);
        return;
    }
    if (_waveform && _currentWaveformRenderer) {
        [_currentWaveformRenderer dipBarsFromFraction:_convertSweepFraction toFraction:fraction];
    }
    _convertSweepFraction = fraction;
}

- (void)prepareForWaveformLoad {
    [self hideLoadingIndicator];
    [self hideEmptyPlaceholder];
    // Otherwise a stale hover playhead would sit over the next track's
    // waveform until the mouse moved again.
    [self hideHoverIndicator];
    _convertSweepFraction = 0;
    _waveform = nil;
    if (!_currentWaveformRenderer) {
        // Prefer the persisted style, then the app default. allKeys[0] is a
        // last resort only, because NSMutableDictionary key order is
        // unspecified and it would otherwise pick an arbitrary renderer from
        // one run to the next.
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
    [self hideHoverIndicator];
    // Collapse any previous track's waveform, so the shimmer stands alone.
    _convertSweepFraction = 0;
    _waveform = nil;
    self.progress = 0;
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CAGradientLayer *shimmer = [CAGradientLayer layer];
    shimmer.contentsScale = VibeBackingScaleForWindow(self.window);
    shimmer.startPoint = CGPointMake(0, 0.5);
    shimmer.endPoint = CGPointMake(1, 0.5);
    shimmer.colors = [self shimmerColors];
    [self.layer addSublayer:shimmer];
    _loadingLayer = shimmer;

    // The frame and the sweep both depend on the current bounds, so a helper
    // keeps them in sync when the window resizes, or the small-large layout
    // toggles, mid-load.
    [self layoutLoadingLayer];
}

// Follows the appearance, as the renderer palettes do, because a fixed white
// band is near-invisible on a light background. showLoadingIndicator and
// updateAppearance share it, so that a light-dark flip mid-load recolors the
// live shimmer.
- (NSArray *)shimmerColors {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return @[
            (id)[base colorWithAlphaComponent:0].CGColor,
            (id)[base colorWithAlphaComponent:0.55].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

// Positions the shimmer band and installs, or reinstalls, its sweep for the
// current bounds.
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

    // Reinstall the sweep only when its endpoints actually change. Live resize
    // lands here every frame, and an unconditional remove-and-re-add restarts
    // the 1.2s sweep each time, freezing it at the left edge.
    NSNumber *fromValue = @(-bandWidth / 2);
    NSNumber *toValue = @(width + bandWidth / 2);
    CABasicAnimation *current = (CABasicAnimation *)[_loadingLayer animationForKey:@"sweep"];
    if ([current isKindOfClass:CABasicAnimation.class] &&
        [current.fromValue isEqual:fromValue] && [current.toValue isEqual:toValue]) {
        return;
    }
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweep.fromValue = fromValue;
    sweep.toValue = toValue;
    sweep.duration = 1.2;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (current) {
        // Carry the running sweep's phase over, so the retargeted band keeps
        // moving from its current spot rather than snapping to the left edge.
        // The phase is elapsed time plus the previous carry-over: animationForKey:
        // returns a copy that preserves timeOffset, so dropping it here would lose
        // the phase on every reinstall after the first. beginTime is 0 until the
        // first transaction commit stamps it; treat elapsed as 0 then.
        CFTimeInterval now = [_loadingLayer convertTime:CACurrentMediaTime() fromLayer:nil];
        CFTimeInterval elapsed = current.beginTime > 0 ? MAX(now - current.beginTime, 0) : 0;
        sweep.timeOffset = fmod(elapsed + current.timeOffset, sweep.duration);
    }
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
    [self hideHoverIndicator];
    _convertSweepFraction = 0;
    _waveform = nil;
    self.progress = 0;
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CALayer *line = [CALayer layer];
    line.contentsScale = VibeBackingScaleForWindow(self.window);
    [self.layer addSublayer:line];
    _placeholderLayer = line;

    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

// The same 2pt midline band the shimmer sweeps, but full-width and static.
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
    // Half the shimmer's 0.55 peak, so that the empty state recedes.
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
    if (sizeChanged && _currentWaveformRenderer) {
        // Sync the geometry even with no waveform. Otherwise the collapse
        // morph after a track change keeps rebuilding at the old size for the
        // rest of the collapse.
        [self drawWaveform];
    }
    if (sizeChanged && _loadingLayer) {
        // Keep the shimmer centered, spanning the new width, mid-load.
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

// Keeps the manually created layer tree — the renderer sublayers, masks and
// gradients — at the window's backing scale. The root layer is layer-hosted, so
// AppKit does not manage contentsScale for us.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    CGFloat scale = VibeBackingScaleForWindow(self.window);
    applyContentsScale(self.layer, scale);
    // Settled geometry is snapped to the old display's pixel grid, and the
    // same-size draw path skips the rebuild; ask for it explicitly. Must run
    // after the scale re-stamp above, which the rebuild reads.
    [_currentWaveformRenderer backingScaleDidChange];
}

// Fires when the system switches between light and dark; under the "System
// default" appearance the window follows the OS. Without this, the cached
// renderer colors go stale until a manual View > Appearance toggle.
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
    if (_loadingLayer) {
        _loadingLayer.colors = [self shimmerColors];
    }
}

@end
