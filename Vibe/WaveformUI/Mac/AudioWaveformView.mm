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
// second. The iOS scrubber's pace, so a load fills in alike on both.
static const NSTimeInterval kPartialWaveformInterval = 0.4;

// A landing's newly decoded stretch grows up from the resting line. Under
// kPartialWaveformInterval, so one reveal ends before the next lands; a steep
// ease in and out, so it reads as a snap rather than a drift. The iOS
// scrubber's kChunkGrowDuration.
static const CFTimeInterval kRevealGrowDuration = 0.2;

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
    // The renderer's tree, apart from the view's own overlays so a reveal
    // can mask the waveform alone.
    CALayer*                    _rendererHost;
    // The theme's playhead line; hidden until a theme asks for it.
    CALayer*                    _playheadLine;
    // The streaming pace: when a partial last landed, and which pending one
    // may land (a reset or a newer delivery supersedes it).
    CFTimeInterval              _partialLandedAt;
    NSUInteger                  _partialGeneration;
    // The running reveal's overlay and the stretch it grows, as fractions so a
    // resize can lay it out again.
    CALayer*                    _revealLayer;
    double                      _revealFrom;
    double                      _revealTo;
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

    _rendererHost = [CALayer layer];
    _rendererHost.anchorPoint = CGPointZero;
    _rendererHost.frame = self.bounds;
    [self.layer addSublayer:_rendererHost];

    _playheadLine = [CALayer layer];
    _playheadLine.hidden = YES;
    [self.layer addSublayer:_playheadLine];

    _progress = 0;
    _progressTracker = 0;
    _didClickInside = NO;
}

- (void)setWaveformStyle:(NSString*)identifier {
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:identifier];
    if (!_currentWaveformRenderer || ![_styleIdentifier isEqualToString:style]) {
        _styleIdentifier = style;
        [self endReveal];
        _currentWaveformRenderer = [WaveformRendererRegistry rendererForResolvedIdentifier:style
                layer:_rendererHost bounds:self.bounds isDark:self.isDark];
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
    [self endReveal];
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

// The iOS scrubber's pace, in the live tree: a load's first waveform eases up
// from the midline, and every later one lands at a steady pace, settled, its
// newly decoded stretch growing in (revealFrom:to:before:after:) — eased one
// by one they kept the whole load repainting the full mask on every frame.
// The complete one waits its turn too, so it never cuts the last stretch's
// grow short.
//
// TRAP: the first waveform lands at once, never held for its load to complete
// as the scrubber's is. Every track change starts a load here, so holding it
// left the outgoing track's bars collapsing into an empty strip for half a
// second after every skip, where they had morphed straight into the new ones.
- (void)showWaveform:(CodableAudioWaveform *)waveform {
    NSUInteger generation = ++_partialGeneration;
    if (!_waveform) {
        [self landWaveform:waveform];
        return;
    }
    NSTimeInterval wait = MAX(0, _partialLandedAt + kPartialWaveformInterval - CACurrentMediaTime());
    __weak AudioWaveformView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AudioWaveformView *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_partialGeneration) {
            return;
        }
        [strongSelf landWaveform:waveform];
    });
}

// Eased only onto nothing, or when Normalize raises the complete waveform,
// whose every bar then grows; the morph carries the last stretch up with it.
// Any other ease only re-rounds bars already drawn, a shimmer across the
// whole width.
- (void)landWaveform:(CodableAudioWaveform *)waveform {
    CodableAudioWaveform *previous = _waveform;
    BOOL eases = !previous || [_currentWaveformRenderer normalizationGainForWaveform:waveform.waveform] > 1.001;
    double from = previous ? previous.waveform->getDecodedFraction() : 1;
    double to = waveform.waveform->getDecodedFraction();
    // Ended first: the picture it is about to render must be the whole one.
    [self endReveal];
    BOOL reveals = !eases && to > from && [WaveformRendererRegistry supportsLevelsForIdentifier:_styleIdentifier];
    CGImageRef before = reveals ? [self newImageOfHostFrom:from to:1] : NULL;
    _waveform = waveform;
    _partialLandedAt = CACurrentMediaTime();
    [self drawWaveform];
    if (!eases) {
        [_currentWaveformRenderer settleMorphImmediately];
    }
    if (before) {
        CGImageRef after = [self newImageOfHostFrom:from to:to];
        if (after) {
            [self revealFrom:from to:to before:before after:after];
        }
        CGImageRelease(after);
        CGImageRelease(before);
    }
}

#pragma mark - The streaming reveal

// The iOS scrubber's reveal (iOS/AGENTS.md), from two renders of the live tree
// a landing in place of a rebuild a frame: past the old edge the picture is
// three layers over the host, which is masked to the part before it. The new
// stretch, scaled up from the style's resting line; under it the old picture,
// fading over the first half of the grow so the midline is drawn while the
// stretch is a hairline and gone before the translucent stretch would show it
// through; and the old picture's undecoded rest, standing still, so neither
// its line nor a new bar straddling the new edge moves. The overlay sits under
// the playhead line and grows alike on either side of the playhead.
//
// A newer landing replaces it and any reset or style change ends it; the
// stretch it was growing then stands at once. Cupertino Basic never reads the
// samples, so it has none.
- (void)revealFrom:(double)from to:(double)to before:(CGImageRef)before after:(CGImageRef)after {
    _revealFrom = from;
    _revealTo = to;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *mask = [CALayer layer];
    mask.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _rendererHost.mask = mask;
    CALayer *overlay = [CALayer layer];
    for (id contents in @[(__bridge id)before, (__bridge id)before, (__bridge id)after]) {
        CALayer *part = [CALayer layer];
        part.contents = contents;
        [overlay addSublayer:part];
    }
    _revealLayer = overlay;
    [self.layer insertSublayer:overlay above:_rendererHost];
    [self layoutReveal];
    // Set before the animations, which it then waits for.
    __weak AudioWaveformView *weakSelf = self;
    [CATransaction setCompletionBlock:^{
        AudioWaveformView *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_revealLayer == overlay) {
            [strongSelf endReveal];
        }
    }];
    CALayer *underlay = overlay.sublayers[0];
    underlay.opacity = 0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = kRevealGrowDuration / 2;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [underlay addAnimation:fade forKey:@"underlayFade"];
    // From a device pixel, not from nothing, so the stretch starts as a line.
    CGFloat pixels = _rendererHost.bounds.size.height * VibeBackingScaleOrDefault(self.window.backingScaleFactor);
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
    grow.fromValue = @(MIN(1.0, 1 / MAX(1.0, pixels)));
    grow.toValue = @1;
    grow.duration = kRevealGrowDuration;
    grow.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.7f :0.0f :0.3f :1.0f];
    [overlay.sublayers[2] addAnimation:grow forKey:@"revealGrow"];
    [CATransaction commit];
}

// From the fractions, so a resize mid-reveal stretches the renders to where
// they belong.
- (void)layoutReveal {
    if (!_revealLayer) {
        return;
    }
    CGRect bounds = _rendererHost.bounds;
    CGFloat height = bounds.size.height;
    CGFloat left = [self revealEdgeX:_revealFrom];
    CGFloat edge = [self revealEdgeX:_revealTo];
    CGFloat right = bounds.size.width;
    // Where the new edge falls in the old picture's render.
    CGFloat split = right > left ? (edge - left) / (right - left) : 1;
    CGFloat restingY = CGRectGetMidY([_currentWaveformRenderer restingBandForBounds:bounds]);
    NSArray<CALayer *> *parts = _revealLayer.sublayers;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _revealLayer.frame = bounds;
    _rendererHost.mask.frame = CGRectMake(0, 0, left, height);
    parts[0].frame = CGRectMake(left, 0, edge - left, height);
    parts[0].contentsRect = CGRectMake(0, 0, split, 1);
    parts[1].frame = CGRectMake(edge, 0, right - edge, height);
    parts[1].contentsRect = CGRectMake(split, 0, 1 - split, 1);
    parts[2].anchorPoint = CGPointMake(0, height > 0 ? restingY / height : 0.5);
    parts[2].bounds = CGRectMake(0, 0, edge - left, height);
    parts[2].position = CGPointMake(left, restingY);
    [CATransaction commit];
}

// On the device-pixel grid, so a render lands on the pixels it was made from.
- (CGFloat)revealEdgeX:(double)fraction {
    CGFloat scale = VibeBackingScaleOrDefault(self.window.backingScaleFactor);
    return round(fraction * _rendererHost.bounds.size.width * scale) / scale;
}

// The host's picture over [from, to) of the track, as the screen draws it.
- (CGImageRef)newImageOfHostFrom:(double)from to:(double)to CF_RETURNS_RETAINED {
    CGFloat left = [self revealEdgeX:from];
    CGFloat right = [self revealEdgeX:to];
    CGContextRef ctx = VibeNewEnvelopeBitmapContext(CGSizeMake(right - left, _rendererHost.bounds.size.height),
                                                    VibeBackingScaleOrDefault(self.window.backingScaleFactor));
    if (!ctx) {
        return NULL;
    }
    CGContextTranslateCTM(ctx, -left, 0);
    [_rendererHost renderInContext:ctx];
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

- (void)endReveal {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_revealLayer removeFromSuperlayer];
    _revealLayer = nil;
    _rendererHost.mask = nil;
    [CATransaction commit];
}

- (void)setFrameSize:(NSSize)newSize {
    BOOL sizeChanged = !NSEqualSizes(newSize, self.frame.size);
    [super setFrameSize:newSize];
    if (!sizeChanged) {
        return;
    }
    // Before the redraw, which the renderer lays out from the host.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.frame = self.bounds;
    [CATransaction commit];
    [self layoutReveal];
    if (_currentWaveformRenderer) {
        // Even with no waveform: a collapse morph in flight would otherwise
        // keep rebuilding at the old size.
        [self drawWaveform];
    }
    if (_loadingIndicator) {
        [self layoutLoadingLayer];
    }
    if (_placeholderLayer) {
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
