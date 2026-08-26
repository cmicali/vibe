//
//  AudioWaveformView.mm
//  Vibe
//

#import "AudioWaveformViewInternal.h"
#import "AudioWaveformView+Loading.h"
#import "WaveformRendererRegistry.h"
#import "NSView+DarkMode.h"
#import "AppSettings.h"
#import "Formatters.h"
#import "VibeStrings.h"

// A press that travels further than this is a drag, not a click.
static const CGFloat kWaveformDragHysteresis = 4;

@implementation AudioWaveformView {
    CGFloat                     _progress;
    NSUInteger                  _progressTracker;
    // The convert sweep's front: bars left of it have already been dipped.
    double                      _convertSweepFraction;
    BOOL                        _didClickInside;
    NSTrackingArea*             _hoverTrackingArea;
    // The gesture's state, valid while _didClickInside: the mode is stashed at
    // mouse-down so a settings write cannot change it mid-drag.
    NSString*                   _dragBehavior;
    NSPoint                     _mouseDownPoint;
    NSPoint                     _windowOriginAtMouseDown;
    BOOL                        _isDragSeeking;
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
}

- (NSString *)currentWaveformStyle {
    return [_currentWaveformRenderer.class styleIdentifier];
}

- (void)setWaveformStyle:(NSString*)identifier {
    Class renderer = [WaveformRendererRegistry rendererClassForIdentifier:identifier];
    if (!renderer) {
        // Unknown identifier (hand-edited default, or a style dropped in a
        // later version): fall back rather than leaving a blank waveform.
        renderer = [WaveformRendererRegistry rendererClassForIdentifier:SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT];
        if (!renderer) {
            return;
        }
    }
    _currentWaveformRenderer = [[renderer alloc] initWithLayer:self.layer bounds:self.bounds isDark:self.isDark];
    [self applyResolvedTheme];
    [self drawWaveform];
    [self updateRendererProgress];
}

// The one resolution site on this view: settings + appearance +
// artworkThemeColor into the renderer's palette.
- (void)applyResolvedTheme {
    if (!_currentWaveformRenderer) {
        return;
    }
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL isDark = self.isDark;
    WaveformTheme *resolved = [WaveformTheme themeForIdentifier:theme.waveformTheme
                                                          isDark:isDark
                                                    artworkColor:self.artworkThemeColor
                                                    customPlayed:[theme waveformPlayedColorForDark:isDark]
                                                  customUnplayed:[theme waveformUnplayedColorForDark:isDark]];
    resolved.flatFill = !theme.waveformGradient;
    _currentWaveformRenderer.theme = resolved;
    [_currentWaveformRenderer updateColors:isDark];
}

- (void)refreshThemeColors {
    if (!_currentWaveformRenderer) {
        return;
    }
    [self applyResolvedTheme];
    // updateColors: left the -1 boundary sentinel; this repaints everything.
    [self updateRendererProgress];
}

- (NSString *)displayNameForStyle:(NSString *)identifier {
    return [WaveformRendererRegistry displayNameForIdentifier:identifier];
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
    return [WaveformRendererRegistry availableIdentifiers];
}

- (void)mouseDown:(NSEvent *)event {
    _didClickInside = NO;
    _isDragSeeking = NO;
    if (!_waveform || !_currentWaveformRenderer || self.bounds.size.width <= 0) {
        // Nothing to scrub — empty, loading, parked — so the whole surface
        // drags the window, as it always did.
        [self.window performWindowDragWithEvent:event];
        return;
    }
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if ([self mouse:mouseLoc inRect:self.bounds]) {
        NSRect band = [_currentWaveformRenderer seekHitBandForBounds:self.bounds];
        if (mouseLoc.y >= NSMinY(band) && mouseLoc.y <= NSMaxY(band)) {
            _didClickInside = YES;
            _dragBehavior = AppSettings.sharedInstance.waveformDragBehavior;
            _mouseDownPoint = mouseLoc;
            _windowOriginAtMouseDown = self.window.frame.origin;
            return;
        }
    }
    // Outside the seek band the drag is the window's in every mode.
    [self.window performWindowDragWithEvent:event];
}

// Seek-on-drag tracks the cursor with the hover highlight; the audio is
// seeked once, on release. In drag_window mode the hysteresis decides:
// past it the rest of the gesture is handed to the window's own drag, and
// only a click that never crossed it seeks from mouseUp:.
- (void)mouseDragged:(NSEvent *)event {
    if (!_didClickInside) {
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!_isDragSeeking &&
        hypot(p.x - _mouseDownPoint.x, p.y - _mouseDownPoint.y) <= kWaveformDragHysteresis) {
        return;
    }
    if (![_dragBehavior isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK]) {
        // Disarm before the handoff: after it the remaining events belong to
        // the window's drag, and a mouseUp that does arrive must not seek.
        _didClickInside = NO;
        [self.window performWindowDragWithEvent:event];
        return;
    }
    // Once past the hysteresis the drag tracks even outside the band or the
    // view; the clamp decides the column, like every system slider.
    _isDragSeeking = YES;
    [_currentWaveformRenderer setHoverHighlightX:[self clampedSeekX:p.x]];
}

- (void)mouseUp:(NSEvent *)event {
    BOOL wasDragSeeking = _isDragSeeking;
    _isDragSeeking = NO;
    if (!_didClickInside) {
        return;
    }
    _didClickInside = NO;
    if (!_waveform || !_currentWaveformRenderer || self.bounds.size.width <= 0) {
        return;
    }
    NSPoint e = [event locationInWindow];
    NSPoint mouseLoc = [self convertPoint:e fromView:nil];
    if (wasDragSeeking) {
        // The drag may legitimately end outside the view, so the containment
        // test below does not apply; the clamped column is the target.
        [self.delegate audioWaveformView:self
                                 didSeek:(float) ([self clampedSeekX:mouseLoc.x] / self.bounds.size.width)];
        if (!NSPointInRect(mouseLoc, self.bounds)) {
            [self hideHoverIndicator];
        }
        return;
    }
    if ([_dragBehavior isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW]) {
        // A moved mouse must never seek. The window-origin check catches the
        // server-side background drag, where the view-local point barely moves
        // because the window traveled with the cursor; the local-point check
        // covers delivery where it doesn't.
        NSPoint origin = self.window.frame.origin;
        if (hypot(origin.x - _windowOriginAtMouseDown.x,
                  origin.y - _windowOriginAtMouseDown.y) > kWaveformDragHysteresis ||
            hypot(mouseLoc.x - _mouseDownPoint.x,
                  mouseLoc.y - _mouseDownPoint.y) > kWaveformDragHysteresis) {
            return;
        }
    }
    if ([self mouse:mouseLoc inRect:[self bounds]]) {
        CGFloat x = mouseLoc.x - self.bounds.origin.x;
        float p = (float) (x / self.bounds.size.width);
        [self.delegate audioWaveformView:self didSeek:p];
    }
}

- (CGFloat)clampedSeekX:(CGFloat)x {
    return MAX((CGFloat) 0, MIN(x, self.bounds.size.width));
}

- (BOOL)isOpaque {
    return NO;
}

// TRAP: a constant NO on purpose. AppKit caches this answer in the window's
// movable-background region when the view joins the window, so a value
// derived from the drag setting or the loaded state goes stale the moment
// either changes — the seek mode then scrubbed while the server-side drag
// moved the window with it. The view owns every drag that starts on it, and
// the modes that move the window hand their gesture to
// performWindowDragWithEvent:, a per-gesture decision nothing caches.
- (BOOL)mouseDownCanMoveWindow {
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
    _didClickInside = NO;
    // A track change mid-drag makes the release a no-op.
    _isDragSeeking = NO;
    _convertSweepFraction = 0;
    _waveform = nil;
    self.progress = 0;
}

- (void)prepareForWaveformLoad {
    [self hideLoadingIndicator];
    [self hideEmptyPlaceholder];
    [self resetWaveformContentState];
    if (!_currentWaveformRenderer) {
        // Prefer the persisted style, then the app default; the registry owns
        // the chain.
        [self setWaveformStyle:[WaveformRendererRegistry
                resolveStyleIdentifier:AppSettings.sharedInstance.currentTheme.waveformStyle]];
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
    if (sizeChanged && _loadingIndicator) {
        // Keep the shimmer centered, spanning the new width, mid-load.
        [self layoutLoadingLayer];
    }
    if (sizeChanged && _placeholderLayer) {
        [self layoutPlaceholderLayer];
    }
}

// Keeps the manually created layer tree — the renderer sublayers, masks and
// gradients — at the window's backing scale. The root layer is layer-hosted, so
// AppKit does not manage contentsScale for us.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    CGFloat scale = VibeBackingScaleForWindow(self.window);
    VibeApplyContentsScale(self.layer, scale);
    [_loadingIndicator updateContentsScale:scale];
    // Settled geometry is snapped to the old display's pixel grid, and the
    // same-size draw path skips the rebuild; ask for it explicitly. Must run
    // after the scale re-stamp above, which the rebuild reads.
    [_currentWaveformRenderer backingScaleDidChange];
}

// Fires when the system switches between light and dark; under the "System
// default" appearance the window follows the OS. Without this, the cached
// renderer colors go stale until a manual View > Appearance toggle.
#pragma mark - Accessibility

// The waveform is the only way to seek with the pointer, so to VoiceOver it is
// a slider over the track: the label names it, the value is how far in
// playback has reached, and increment/decrement seek through the same delegate
// method a click does. Without this the whole strip was an unlabelled group
// and the app had no reachable seek at all.
//
// The step is a fraction of the track rather than a number of seconds because
// this view has no duration — it is handed a 0-1 progress and reports a 0-1
// seek, and nothing else. Five percent crosses a song in twenty presses and an
// hour-long mix in the same twenty, which is the right shape for a control
// whose whole width is the track.
static const CGFloat kWaveformAccessibilityStep = 0.05;

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilitySliderRole;
}

- (NSString *)accessibilityLabel {
    return STR_A11Y_WAVEFORM;
}

// A spoken percentage, not the raw fraction: VoiceOver reads an NSNumber
// verbatim, so 0.5 would be announced as "zero point five".
- (id)accessibilityValue {
    return [Formatters.sharedInstance percentString:_progress];
}

- (BOOL)accessibilityPerformIncrement {
    return [self seekAccessibilityByDelta:kWaveformAccessibilityStep];
}

- (BOOL)accessibilityPerformDecrement {
    return [self seekAccessibilityByDelta:-kWaveformAccessibilityStep];
}

// Reports the seek and lets the delegate's playback position come back around
// through setProgress:, exactly as a click does. Writing _progress here would
// show a playhead that had not moved yet, and fight the next UI tick.
- (BOOL)seekAccessibilityByDelta:(CGFloat)delta {
    if (!_waveform || !_currentWaveformRenderer) {
        return NO; // nothing loaded: there is no position to move
    }
    CGFloat target = MAX(0.0, MIN(1.0, _progress + delta));
    if (target == _progress) {
        return NO;
    }
    [self.delegate audioWaveformView:self didSeek:(float)target];
    return YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateAppearance];
}

- (void)updateAppearance {
    if (_currentWaveformRenderer) {
        BOOL isDark = self.isDark;
        if (_currentWaveformRenderer.isDark != isDark) {
            // The theme is resolved per appearance, so a flip re-resolves it
            // rather than merely recoloring: white's base and the album-art
            // legibility clamp both depend on isDark.
            [self applyResolvedTheme];
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
