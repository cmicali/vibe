//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformViewInternal.h"
#import "AudioWaveformView+Loading.h"
#import "DetailedAudioWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#import "BasicAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "NSView+DarkMode.h"
#import "AppSettings.h"

@implementation AudioWaveformView {
    CGFloat                     _progress;
    NSUInteger                  _progressTracker;
    // The convert sweep's front: bars left of it have already been dipped.
    double                      _convertSweepFraction;
    BOOL                        _didClickInside;
    // The renderer classes, keyed by styleIdentifier and instantiated on
    // selection.
    NSMutableDictionary<NSString *, Class>* _waveformRenderers;
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
    // A nil key raises, so the registry never takes one: the base class
    // asserts on the missing override, and this keeps a Release build with an
    // unoverridden subclass down to one missing style.
    NSString *identifier = [renderer styleIdentifier];
    if (identifier.length == 0) {
        LogError(@"Waveform renderer %@ has no style identifier; not registering it",
                 NSStringFromClass(renderer));
        return;
    }
    _waveformRenderers[identifier] = renderer;
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
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)self.devicePixelWidth);
    NSUInteger p = static_cast<NSUInteger>(progress * steps);
    if (_progressTracker != p) {
        _progressTracker = p;
        [self updateRendererProgress];
    }
}

- (CGFloat)progress {
    return _progress;
}

- (CGFloat)devicePixelWidth {
    return self.bounds.size.width * VibeBackingScaleForWindow(self.window);
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
    // Unconditional: the track and fill layers re-colour whether or not a
    // shimmer is currently up.
    [self updateLoadingColors];
}

@end
