//
//  AudioWaveformView.mm
//  Vibe
//

#import "AudioWaveformViewInternal.h"
#import "AudioWaveformView+Loading.h"
#import "WaveformRendererRegistry.h"
#import "NSView+DarkMode.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Formatters.h"
#import "VibeStrings.h"

// A press that travels further than this is a drag, not a click.
static const CGFloat kWaveformDragHysteresis = 4;

// How often a streaming load's partial waveform lands: it delivers ~10 times a
// second. The iOS scrubber's pace, so a load fills in alike on both. The first
// partial waits for its load to complete as long as the scrubber's does.
static const NSTimeInterval kPartialWaveformInterval = 0.4;
static const NSTimeInterval kFirstPartialDelay = 0.5;

@implementation AudioWaveformView {
    NSString                    *_styleIdentifier;
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
    // The theme's playhead line; hidden until a theme asks for it.
    CALayer*                    _playheadLine;
    // The streaming pace: when this load first delivered and a partial last
    // landed, and which pending one may land (a reset or a newer delivery
    // supersedes it).
    CFTimeInterval              _firstDeliveryAt;
    CFTimeInterval              _partialLandedAt;
    NSUInteger                  _partialGeneration;
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

    // Layer before wantsLayer, or the view ends up layer-backed rather than
    // layer-hosting.
    self.layer = [[CALayer alloc] init];
    self.wantsLayer = YES;

    _playheadLine = [CALayer layer];
    _playheadLine.hidden = YES;
    // A style change adds its renderer's tree above every older sublayer.
    _playheadLine.zPosition = 1;
    [self.layer addSublayer:_playheadLine];

    _progress = 0;
    _progressTracker = 0;
    _didClickInside = NO;
}

- (void)setWaveformStyle:(NSString*)identifier {
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:identifier];
    if (!_currentWaveformRenderer || ![_styleIdentifier isEqualToString:style]) {
        _styleIdentifier = style;
        _currentWaveformRenderer = [WaveformRendererRegistry rendererForResolvedIdentifier:style
                layer:self.layer bounds:self.bounds isDark:self.isDark];
        [self applyLevelSettings];
        [self applyResolvedTheme];
    }
    _currentWaveformRenderer.barDensity = AppSettings.sharedInstance.currentTheme.waveformBarDensity;
    _currentWaveformRenderer.barWidthScale = AppSettings.sharedInstance.currentTheme.waveformBarWidth;
    [self drawWaveform];
    [self updateRendererProgress];
}

- (void)applyLevelSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    _currentWaveformRenderer.normalizesLevels = settings.waveformNormalize;
    _currentWaveformRenderer.gainDB = (float)settings.waveformGainDB;
}

- (void)refreshWaveformLevels {
    if (!_currentWaveformRenderer) {
        return;
    }
    [self applyLevelSettings];
    [self drawWaveform];
}

// The one resolution site on this view: settings + appearance +
// artworkThemeColor into the renderer's palette.
- (void)applyResolvedTheme {
    if (!_currentWaveformRenderer) {
        return;
    }
    BOOL isDark = self.isDark;
    WaveformTheme *theme = [WaveformTheme themeForAppTheme:AppSettings.sharedInstance.currentTheme
                                                    isDark:isDark
                                              artworkColor:self.artworkThemeColor];
    _currentWaveformRenderer.theme = theme;
    [_currentWaveformRenderer updateColors:isDark];
    [self.delegate audioWaveformViewDidResolveTheme:self];
}

- (void)refreshThemeColors {
    if (!_currentWaveformRenderer) {
        return;
    }
    [self applyResolvedTheme];
    // updateColors: left the -1 boundary sentinel; this repaints everything.
    [self updateRendererProgress];
}

- (void)drawWaveform {
    VibeSignpostBegin(waveform_update);
    [_currentWaveformRenderer updateWaveform:self.bounds progress:[self playedProgress]
                                    waveform:self.waveform.waveform];
    [self layoutPlayheadLine];
    VibeSignpostEnd(waveform_update);
}

- (void)updateRendererProgress {
    VibeSignpostBegin(waveform_progress);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_currentWaveformRenderer updateProgress:[self playedProgress] waveform:self.waveform.waveform];
    [CATransaction commit];
    [self layoutPlayheadLine];
    VibeSignpostEnd(waveform_progress);
}

// Under a playhead line the renderer draws the whole waveform as played, and
// the line alone carries the position.
- (CGFloat)playedProgress {
    return _currentWaveformRenderer.theme.playheadColor ? 1 : _progress;
}

// Hidden with nothing loaded, as hover and seek are.
- (void)layoutPlayheadLine {
    VibeColor *color = _waveform ? _currentWaveformRenderer.theme.playheadColor : nil;
    if (!color && _playheadLine.hidden) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playheadLine.hidden = !color;
    if (color) {
        CGRect bounds = self.bounds;
        _playheadLine.backgroundColor = color.CGColor;
        _playheadLine.frame = VibePlayheadLineRect(bounds.size.width * _progress,
                [_currentWaveformRenderer seekHitBandForBounds:bounds], bounds.size.width,
                VibeBackingScaleOrDefault(self.window.backingScaleFactor));
    }
    [CATransaction commit];
}

- (void)mouseDown:(NSEvent *)event {
    _didClickInside = NO;
    _isDragSeeking = NO;
    if (!_waveform || !_currentWaveformRenderer || self.bounds.size.width <= 0) {
        // Nothing to scrub (empty, loading, parked): the surface drags the
        // window.
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

// Past the hysteresis, seek mode tracks the cursor with the hover highlight
// and seeks once on release; drag_window mode hands the gesture to the window.
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
        // Disarmed first: a mouseUp that still arrives must not seek.
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
        // May legitimately end outside the view: no containment test.
        [self.delegate audioWaveformView:self
                                 didSeek:(float) ([self clampedSeekX:mouseLoc.x] / self.bounds.size.width)];
        if (!NSPointInRect(mouseLoc, self.bounds)) {
            [self hideHoverIndicator];
        }
        return;
    }
    if ([_dragBehavior isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW]) {
        // A moved mouse never seeks. The window-origin check catches a drag
        // that moved the window with the cursor, where the local point barely
        // moves.
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

// TRAP: a constant NO. AppKit caches this answer in the window's movable
// region when the view joins the window, so one derived from the drag setting
// or the loaded state goes stale — seek mode then scrubbed while the window
// moved. Moving the window is per gesture, via performWindowDragWithEvent:.
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

#pragma mark - Hover scrubbing affordance

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverTrackingArea) {
        [self removeTrackingArea:_hoverTrackingArea];
    }
    // ActiveAlways, like the window's hover-reveal chrome.
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
    // Stored unconditionally; only the repaint is gated, per device pixel. A
    // track-proportional step would stall the boundary for seconds on an
    // hour-long mix and swallow small seeks.
    _progress = progress;
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
    return self.bounds.size.width * VibeBackingScaleOrDefault(self.window.backingScaleFactor);
}

- (double)convertSweepFraction {
    return _convertSweepFraction;
}

// Only the span newly crossed is dipped: bars behind the front are already
// easing home.
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

// Every presentation reset's shared teardown, so the three cannot drift.
// Callers hide their overlays and redraw themselves.
- (void)resetWaveformContentState {
    _partialGeneration++;
    _firstDeliveryAt = 0;
    _partialLandedAt = 0;
    [self hideHoverIndicator];
    _didClickInside = NO;
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
        [self setWaveformStyle:AppSettings.sharedInstance.currentTheme.waveformStyle];
    }
    [self drawWaveform];
}

// The iOS scrubber's model, in the live tree: a waveform eases up from the
// midline once, at its final heights if its load completes within
// kFirstPartialDelay; a slower load's partials land settled at a steady pace —
// eased one by one they kept the whole load repainting the full mask on every
// frame — and the complete one eases to its normalized heights.
- (void)showWaveform:(CodableAudioWaveform *)waveform {
    NSUInteger generation = ++_partialGeneration;
    CFTimeInterval now = CACurrentMediaTime();
    if (_firstDeliveryAt == 0) {
        _firstDeliveryAt = now;
    }
    if (waveform.waveform->isComplete()) {
        _waveform = waveform;
        [self drawWaveform];
        return;
    }
    NSTimeInterval wait = _waveform
            ? MAX(0, _partialLandedAt + kPartialWaveformInterval - now)
            : MAX(0, _firstDeliveryAt + kFirstPartialDelay - now);
    __weak AudioWaveformView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AudioWaveformView *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_partialGeneration) {
            return;
        }
        BOOL arrival = !strongSelf->_waveform;
        strongSelf->_waveform = waveform;
        strongSelf->_partialLandedAt = CACurrentMediaTime();
        [strongSelf drawWaveform];
        if (!arrival) {
            [strongSelf->_currentWaveformRenderer settleMorphImmediately];
        }
    });
}

- (void)setFrameSize:(NSSize)newSize {
    BOOL sizeChanged = !NSEqualSizes(newSize, self.frame.size);
    [super setFrameSize:newSize];
    if (sizeChanged && _currentWaveformRenderer) {
        // Even with no waveform: a collapse morph in flight would otherwise
        // keep rebuilding at the old size.
        [self drawWaveform];
    }
    if (sizeChanged && _loadingIndicator) {
        [self layoutLoadingLayer];
    }
    if (sizeChanged && _placeholderLayer) {
        [self layoutPlaceholderLayer];
    }
}

// Layer-hosted, so AppKit does not manage contentsScale for us.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    CGFloat scale = VibeBackingScaleOrDefault(self.window.backingScaleFactor);
    VibeApplyContentsScale(self.layer, scale);
    [_loadingIndicator updateContentsScale:scale];
    // Settled geometry is snapped to the old pixel grid and the same-size draw
    // skips the rebuild. After the re-stamp above, which the rebuild reads.
    [_currentWaveformRenderer backingScaleDidChange];
    [self layoutPlayheadLine];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (_currentWaveformRenderer) {
        BOOL isDark = self.isDark;
        if (_currentWaveformRenderer.isDark != isDark) {
            // Re-resolved, not just recolored: the mono base and the album-art
            // clamp both depend on isDark.
            [self applyResolvedTheme];
            [self updateRendererProgress];
        }
    }
    if (_placeholderLayer) {
        [self updatePlaceholderColor];
    }
    [self updateLoadingColors];
}

#pragma mark - Accessibility

// A slider over the track: the only pointer seek. A fraction, not seconds:
// the view knows no duration.
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

// VoiceOver reads an NSNumber verbatim: 0.5 is "zero point five".
- (id)accessibilityValue {
    return [Formatters.sharedInstance percentString:_progress];
}

- (BOOL)accessibilityPerformIncrement {
    return [self seekAccessibilityByDelta:kWaveformAccessibilityStep];
}

- (BOOL)accessibilityPerformDecrement {
    return [self seekAccessibilityByDelta:-kWaveformAccessibilityStep];
}

// The position comes back through setProgress:, as for a click. Writing
// _progress here would show a playhead that has not moved and fight the tick.
- (BOOL)seekAccessibilityByDelta:(CGFloat)delta {
    if (!_waveform || !_currentWaveformRenderer) {
        return NO;
    }
    CGFloat target = MAX(0.0, MIN(1.0, _progress + delta));
    if (target == _progress) {
        return NO;
    }
    [self.delegate audioWaveformView:self didSeek:(float)target];
    return YES;
}

@end
