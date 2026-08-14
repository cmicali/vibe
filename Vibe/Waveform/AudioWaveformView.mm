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

// The weight of every non-waveform midline: the loading indicator's three
// layers — track, filled head and shimmer band — and the empty state's static
// line. They are one element in different states, so they share a height and
// cannot drift apart. A whole point keeps the line on device pixels at any
// backing scale: a half-point height would centre at a half pixel and render
// soft, which on a hairline reads as a dimmer line rather than a thinner one.
static const CGFloat kMidlineHeight = 1;

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
    // The determinate download fill beneath the shimmer; nil while progress
    // is unknown. Same presentation as the iOS scrubber's.
    CAGradientLayer*            _loadingProgressLayer;
    CALayer*                    _loadingTrackLayer;
    // Clips the shimmer to the span it is allowed to sweep. The band slides
    // in from before that span and out past its end, and the view's own
    // layer does not mask, so without this it draws over the artwork on one
    // side and out to the window edge on the other.
    CALayer*                    _loadingShimmerClip;
    // The last reported download fraction, or -1 while indeterminate. It sets
    // how much of the track is filled and, from that, where the shimmer is
    // allowed to sweep.
    float                       _loadingProgress;
    // When the last fraction landed, so the fill can be eased over roughly the
    // interval the next one is expected to take. See setLoadingProgress:.
    CFAbsoluteTime              _lastLoadingProgressAt;
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

// The teardown shared by every presentation reset — prepareForWaveformLoad,
// showLoadingIndicator and showEmptyPlaceholder — kept in one place so the
// three cannot drift: clear the previous track's waveform, sweep and hover
// state (a stale hover playhead would otherwise sit over the next
// presentation until the mouse moved). Callers hide whichever overlay layers
// must not survive, and redraw, themselves.
- (void)resetWaveformContentState {
    [self hideHoverIndicator];
    _convertSweepFraction = 0;
    _waveform = nil;
    self.progress = 0;
}

- (void)prepareForWaveformLoad {
    [self hideLoadingIndicator];
    [self hideEmptyPlaceholder];
    [self resetWaveformContentState];
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
    [self drawWaveform];
}

- (void)showLoadingIndicator {
    if (_loadingLayer) {
        return;
    }
    [self hideEmptyPlaceholder];
    // Collapse any previous track's waveform, so the shimmer stands alone.
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    _loadingProgress = -1;
    _lastLoadingProgressAt = 0;

    // The control's body: one midline track, spanning the whole width. The
    // filled head and the shimmer are both read against it, which is what
    // makes the determinate and indeterminate modes one control rather than
    // two — indeterminate is simply nothing filled yet.
    CALayer *track = [CALayer layer];
    track.contentsScale = VibeBackingScaleForWindow(self.window);
    track.backgroundColor = [self inertMidlineColor];
    [self.layer addSublayer:track];
    _loadingTrackLayer = track;

    CALayer *clip = [CALayer layer];
    clip.contentsScale = VibeBackingScaleForWindow(self.window);
    clip.masksToBounds = YES;
    [self.layer addSublayer:clip];
    _loadingShimmerClip = clip;

    CAGradientLayer *shimmer = [CAGradientLayer layer];
    shimmer.contentsScale = VibeBackingScaleForWindow(self.window);
    shimmer.startPoint = CGPointMake(0, 0.5);
    shimmer.endPoint = CGPointMake(1, 0.5);
    shimmer.colors = [self shimmerColors];
    [clip addSublayer:shimmer];
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

// The inert midline, shared by the loading indicator's unfilled track and
// the empty state's static line — the same element, so the same colour.
// Half the shimmer's 0.55 peak: present enough to show how far there is to
// go, faint enough that the shimmer riding it stays the moving part.
- (CGColorRef)inertMidlineColor {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return [base colorWithAlphaComponent:0.275].CGColor;
}

// The filled head, fading out over its last few points so it meets the
// shimmer as a soft front rather than a hard cut.
- (NSArray *)loadingFillColors {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return @[
            (id)[base colorWithAlphaComponent:0.85].CGColor,
            (id)[base colorWithAlphaComponent:0.85].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

// Positions the shimmer band and installs, or reinstalls, its sweep for the
// current bounds.
- (void)layoutLoadingLayer {
    [self layoutLoadingLayerAnimatedOver:0];
}

// duration > 0 eases the parts that track the download's progress; the rest is
// always instant. Resize and state changes pass 0.
- (void)layoutLoadingLayerAnimatedOver:(CFTimeInterval)duration {
    if (!_loadingLayer) {
        return;
    }
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2;
    // The shimmer sweeps the *unfilled* remainder only: it is the "still
    // working on this part" half of one control, and the fill is the "this
    // part is done" half. Indeterminate fills nothing, so the sweep spans the
    // whole width exactly as it always has.
    CGFloat fillEnd = _loadingProgress > 0 ? width * MIN(1.0f, _loadingProgress) : 0;
    CGFloat remainder = MAX(width - fillEnd, 0);
    CGFloat bandWidth = MIN(MAX(width * 0.35, 40), MAX(remainder, 1));

    // The clip is exactly the span the shimmer may occupy, so the band can
    // still slide in and out at the ends without escaping the line. Its left
    // edge is the fill's front, so the two share one transaction: they ease
    // together on a progress sample and snap together on a resize.
    [CATransaction begin];
    if (duration > 0) {
        [CATransaction setAnimationDuration:duration];
        [CATransaction setAnimationTimingFunction:
                [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    }
    else {
        [CATransaction setDisableActions:YES];
    }
    if (_loadingProgressLayer && fillEnd > 0) {
        // A soft front, but only as long as there is remainder to fade into:
        // at completion a fixed fade would read as the bar stopping short of
        // the edge rather than as a soft edge.
        static const CGFloat kFrontFadePoints = 14;
        CGFloat fade = MIN(kFrontFadePoints, remainder);
        _loadingProgressLayer.locations = @[ @0, @(MAX(0.0, (fillEnd - fade) / fillEnd)), @1 ];
        _loadingProgressLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2, fillEnd, kMidlineHeight);
    }
    _loadingShimmerClip.frame = CGRectMake(fillEnd, midY - kMidlineHeight / 2, remainder, kMidlineHeight);
    [CATransaction commit];

    // The band's own position is driven by the sweep animation, so its
    // geometry is always set action-free: an implicit animation here would
    // fight that and stall the sweep.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _loadingLayer.frame = CGRectMake(0, 0, bandWidth, kMidlineHeight);
    // Near completion there is no room left to sweep, so the band fades out
    // rather than jittering in a sliver.
    _loadingLayer.opacity = (float)MIN(1.0, remainder / MAX(width * 0.08, 1));
    _loadingTrackLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2, width, kMidlineHeight);
    [CATransaction commit];

    // Reinstall the sweep only when its endpoints actually change. Live resize
    // lands here every frame, and an unconditional remove-and-re-add restarts
    // the 1.2s sweep each time, freezing it at the left edge.
    NSNumber *fromValue = @(-bandWidth / 2);
    NSNumber *toValue = @(remainder + bandWidth / 2);
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
    [_loadingProgressLayer removeFromSuperlayer];
    _loadingProgressLayer = nil;
    [_loadingShimmerClip removeFromSuperlayer];
    _loadingShimmerClip = nil;
    [_loadingTrackLayer removeFromSuperlayer];
    _loadingTrackLayer = nil;
    _loadingProgress = -1;
    _lastLoadingProgressAt = 0;
}

// Determinate download progress under the shimmer, fed by
// DownloadProgressMonitor: the midline fills from the left as the provider
// materializes the file. A negative fraction hides it (back to
// indeterminate); the shimmer keeps sweeping either way, since a stalled
// provider reports no movement.
// The next ease's length: deliberately shorter than the gap between samples,
// so the fill arrives promptly and then holds at the reported value instead
// of still gliding when the next one lands. Half the last gap, capped —
// providers report around 1 Hz, so this settles in well under half a second
// and rests for the remainder.
- (CFTimeInterval)loadingProgressAnimationDuration {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval gap = _lastLoadingProgressAt > 0 ? now - _lastLoadingProgressAt : 0;
    _lastLoadingProgressAt = now;
    if (gap <= 0) {
        return 0.25; // first sample: no cadence to go on yet
    }
    return MIN(MAX(gap * 0.5, 0.12), 0.45);
}

- (void)setLoadingProgress:(float)fraction {
    if (!_loadingLayer) {
        return;
    }
    _loadingProgress = fraction;
    CGFloat width = self.bounds.size.width;
    CGFloat fillWidth = fraction > 0 ? width * MIN(1.0f, fraction) : 0;
    if (fraction < 0 || fillWidth < 1) {
        [_loadingProgressLayer removeFromSuperlayer];
        _loadingProgressLayer = nil;
        [self layoutLoadingLayer]; // hand the whole width back to the shimmer
        return;
    }
    if (!_loadingProgressLayer) {
        CAGradientLayer *fill = [CAGradientLayer layer];
        fill.contentsScale = VibeBackingScaleForWindow(self.window);
        fill.startPoint = CGPointMake(0, 0.5);
        fill.endPoint = CGPointMake(1, 0.5);
        // Left-anchored: setting the frame then moves only the width, so the
        // eased growth runs from the left edge instead of from the centre.
        fill.anchorPoint = CGPointMake(0, 0.5);
        fill.colors = [self loadingFillColors];
        // Above the track, below the shimmer, so the sweep still reads as it
        // leaves the front.
        [self.layer insertSublayer:fill below:_loadingShimmerClip];
        _loadingProgressLayer = fill;
    }
    // Providers report about once a second and irregularly, so a snap to each
    // value reads as a stalled bar that lurches. Ease to the reported value
    // over roughly the last interval instead: Core Animation retargets from
    // the presentation value, so a sample that lands early redirects the
    // motion rather than jumping. It never runs past what was reported, so a
    // stalled download parks rather than creeping ahead of the truth. The fill
    // is laid out there and nowhere else, so a resize mid-download moves it
    // with the rest of the control rather than at the next sample.
    [self layoutLoadingLayerAnimatedOver:[self loadingProgressAnimationDuration]];
}

- (void)showEmptyPlaceholder {
    if (_placeholderLayer) {
        return;
    }
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
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

// The same midline the loading indicator uses, full-width and static: the
// empty state is that control at rest, so it shares the height and colour.
- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2,
                                         self.bounds.size.width, kMidlineHeight);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    _placeholderLayer.backgroundColor = [self inertMidlineColor];
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
    _loadingTrackLayer.backgroundColor = [self inertMidlineColor];
    _loadingProgressLayer.colors = [self loadingFillColors];
}

@end
