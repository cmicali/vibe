//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberViewInternal.h"
#import "WaveformRendererRegistry.h"
#import "WaveformZoomMath.h"
#import "UIView+DarkMode.h"
#import "AppSettings.h"
#import "Formatters.h"
#import "VibeStrings.h"

// Names the element the XCUITest driver pinches (XCUITest has no
// coordinate-based multi-touch); spelled the same in
// Tests/iOSDriver/VibeiOSDriverTests.m.
static NSString *const kWaveformScrubberIdentifier = @"waveform-scrubber";

@implementation WaveformScrubberView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.opaque = NO;
    self.clipsToBounds = YES;
    self.accessibilityIdentifier = kWaveformScrubberIdentifier;
    _visibleFraction = kVibeWaveformDefaultZoomFraction;

    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.delegate = self;
    _scroll.bounces = YES;
    _scroll.alwaysBounceHorizontal = YES;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.decelerationRate = UIScrollViewDecelerationRateFast;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // TRAP: a UIScrollView owns its pan's delegate and raises on assignment,
    // so the "no waveform, no scrub" gate rides scrollEnabled — see
    // setWaveform:. The pan also dies on any touch-count change, so no
    // maximumNumberOfTouches cap: see trackZoomGestureScrub:.
    _scroll.scrollEnabled = NO;
    [self addSubview:_scroll];

    _rendererHost = [[CALayer alloc] init];
    _rendererHost.geometryFlipped = YES;
    _rendererHost.anchorPoint = CGPointZero;
    _rendererHost.bounds = [self virtualBounds];
    _rendererHost.position = CGPointZero;
    [_scroll.layer addSublayer:_rendererHost];
    _renderWindow = CGRectNull;

    _playheadLine = [CALayer layer];
    _playheadLine.hidden = YES;
    [self.layer addSublayer:_playheadLine];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(handlePinch:)];
    _pinch.delegate = self;
    [self addGestureRecognizer:_pinch];

    __weak WaveformScrubberView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitDisplayScale.class]
                      withHandler:^(id<UITraitEnvironment> env, UITraitCollection *previous) {
                          [weakSelf traitsDidChange:previous];
                      }];
}

- (BOOL)isScrubbing {
    // TRAP: a pinch scrubs only once it has a seek to commit; a pure zoom
    // follows playback. The pinch's fingers keep the pan tracking.
    if (_isPinching) {
        return _seekPending;
    }
    // Finger, coast and bounce: the span the progress writers keep off.
    return _scroll.isDragging || _scroll.isDecelerating || _scroll.isTracking;
}

- (NSArray<NSNumber *> *)scrollGeometry {
    CGFloat minX = -_scroll.contentInset.left;
    CGFloat maxX = _scroll.contentSize.width - _scroll.bounds.size.width + _scroll.contentInset.right;
    return @[@(_scroll.contentOffset.x), @(minX), @(maxX), @(_scroll.contentSize.width)];
}

- (UIPanGestureRecognizer *)scrubPanRecognizer {
    return _scroll.panGestureRecognizer;
}

- (UIPinchGestureRecognizer *)zoomPinchRecognizer {
    return _pinch;
}

- (BOOL)isScrubbingEnabled {
    return self.waveform != nil;
}

- (CGFloat)overscroll {
    CGFloat x = _scroll.contentOffset.x;
    CGFloat minX = -_scroll.contentInset.left;
    CGFloat maxX = _scroll.contentSize.width - _scroll.bounds.size.width + _scroll.contentInset.right;
    if (x < minX) {
        return minX - x;
    }
    if (x > maxX) {
        return maxX - x;
    }
    return 0;
}

// With nothing to scrub the pan must fail, or the pager's
// requireGestureRecognizerToFail: waits forever and an empty strip will not
// swipe. The track sets the zoom floor, so a new one can move the width.
- (void)setWaveform:(CodableAudioWaveform *)waveform {
    CGFloat fraction = [self effectiveVisibleFraction];
    _waveform = waveform;
    _scroll.scrollEnabled = (waveform != nil);
    [self applyVirtualGeometryIfFractionMovedFrom:fraction];
    [self layoutPlayheadLine];
}

- (BOOL)isAnimatingWaveformArrival {
    return self.waveform && !_renderer.isSettled;
}

- (BOOL)isShowingWaveform {
    return self.waveform && _renderer;
}

- (BOOL)isPinching {
    return _isPinching;
}

- (BOOL)seekPending {
    return _seekPending;
}

- (BOOL)isShowingLoadingIndicator {
    return _loadingIndicator != nil;
}

- (BOOL)isShowingCompleteWaveform:(CodableAudioWaveform *)waveform {
    return waveform == self.waveform && waveform.waveform->isComplete();
}

#pragma mark - Zoom

- (CGFloat)displayScale {
    return VibeBackingScaleOrDefault(self.traitCollection.displayScale);
}

// Moves with the view's width, the track and the style, which is why the
// request is kept apart from what is drawn.
- (CGFloat)minimumVisibleFraction {
    AudioWaveform *waveform = self.waveform.waveform;
    double framesPerPoint = !waveform ? 0
            : _renderer ? [_renderer minimumFramesPerPointForWaveform:waveform]
                        : VibeWaveformMinimumFramesPerPoint(waveform->binFrames());
    return VibeWaveformMinimumVisibleFraction(self.bounds.size.width, waveform ? waveform->totalFrames() : 0,
                                              framesPerPoint);
}

- (CGFloat)effectiveVisibleFraction {
    return VibeWaveformClampVisibleFraction(_visibleFraction, [self minimumVisibleFraction]);
}

- (CGFloat)visibleFraction {
    return _visibleFraction;
}

- (void)setVisibleFraction:(CGFloat)fraction {
    fraction = VibeWaveformClampRequestedFraction(fraction);
    if (fraction == _visibleFraction) {
        return;
    }
    CGFloat previous = [self effectiveVisibleFraction];
    _visibleFraction = fraction;
    [self applyVirtualGeometryIfFractionMovedFrom:previous];
}

// A change the floor swallows costs no layout.
- (void)applyVirtualGeometryIfFractionMovedFrom:(CGFloat)fraction {
    if ([self effectiveVisibleFraction] != fraction) {
        [self applyVirtualGeometry];
    }
}

#pragma mark - Renderer lifecycle

// 0 before layout. The EFFECTIVE fraction, so everything derived from it is
// clamped without knowing about the clamp.
- (CGFloat)virtualWidth {
    return self.bounds.size.width / [self effectiveVisibleFraction];
}

- (CGRect)virtualBounds {
    return CGRectMake(0, 0, [self virtualWidth], self.bounds.size.height);
}

- (void)installRendererIfNeeded {
    if (_renderer) {
        return;
    }
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    _styleIdentifier = style;
    _rendererHost.contentsScale = [self displayScale];
    // The renderer reads parentLayer.bounds, so the host must be at virtual
    // size before it exists.
    _rendererHost.bounds = [self virtualBounds];
    _renderer = [WaveformRendererRegistry rendererForResolvedIdentifier:style layer:_rendererHost
                                                        bounds:[self virtualBounds] isDark:self.isDark];
    // The mac's Normalize default, pinned: Normalize and Gain are macOS
    // settings.
    _renderer.normalizesLevels = YES;
    [self applyResolvedTheme];
}

// A track change starts from no renderer, so the next waveform grows out of
// the midline rather than morphing from the last one. Its layers go now: left
// to its dealloc, the old picture stayed up while anything still held it.
- (void)discardRenderer {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.sublayers = nil;
    [CATransaction commit];
    _renderer = nil;
    _renderWindow = CGRectNull;
}

// The one resolution site on this view.
- (void)applyResolvedTheme {
    if (!_renderer) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL isDark = self.isDark;
    WaveformTheme *theme = [WaveformTheme themeForSettings:settings widget:NO isDark:isDark
                                              artworkColor:_artworkThemeColor];
    // No well for it here: the appearance's contrast pole at 68% opacity.
    if ([self drawsPlayheadLine]) {
        theme.playheadColor = [isDark ? UIColor.whiteColor : UIColor.blackColor colorWithAlphaComponent:0.68];
    }
    _renderer.theme = theme;
    [_renderer updateColors:isDark];
    // Geometry, not color, but it changes as these settings do, so the
    // signature carries it.
    _renderer.centered = [settings waveformCenteredForWidget:NO];
    [self layoutPlayheadLine];
    // A playhead line plays the whole waveform.
    [self applyPlayedClip];
    _themeSignature = [self themeSignature];
}

- (BOOL)drawsPlayheadLine {
    return [WaveformRendererRegistry drawsPlayheadLineForIdentifier:_styleIdentifier
                                                             chosen:[AppSettings.sharedInstance waveformPlayheadLineForWidget:NO]];
}

// The resolved palette in both appearances. This page's artwork color counts
// only where the theme reads it. Under album_art a swipe onto a track with
// different art recolors, and under any other theme late art changes
// nothing. The playhead line and Centered ride along.
- (NSString *)themeSignature {
    AppSettings *settings = AppSettings.sharedInstance;
    return [NSString stringWithFormat:@"%d|%d|%@|%@", [self drawsPlayheadLine], [settings waveformCenteredForWidget:NO],
            [WaveformTheme themeForSettings:settings widget:NO isDark:YES artworkColor:_artworkThemeColor].paletteSignature,
            [WaveformTheme themeForSettings:settings widget:NO isDark:NO artworkColor:_artworkThemeColor].paletteSignature];
}

// The signature compare makes a repeated set free, and the pager reconfigures
// a page on every pass through the reuse pool.
- (void)setArtworkThemeColor:(UIColor *)artworkThemeColor {
    _artworkThemeColor = artworkThemeColor;
    [self syncWaveformTheme];
}

- (void)syncWaveformTheme {
    if (!_renderer || [[self themeSignature] isEqualToString:_themeSignature]) {
        return;
    }
    [self applyResolvedTheme];
    // Spectrum's coloring is part of the target. updateColors: only marks it
    // stale, and only a draw refills it.
    [self drawRendererWindowForcing:YES];
}

// The new style lands at once, settled: a swap, not a load. TRAP: lay it out
// again whatever its zoom floor did. Installing sized the host before the
// renderer existed, at the floor of no style. Two Detailed types share a
// floor far deeper, so a swap at deep zoom left a host 2,048 pt wide under
// 320,000 pt of content, and the played side ended far from the playhead.
// The layout draws the new renderer, since discarding cleared its window.
- (void)syncWaveformStyle {
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    if (!_renderer || [style isEqualToString:_styleIdentifier]) {
        return;
    }
    [self discardRenderer];
    [self installRendererIfNeeded];
    [self applyVirtualGeometry];
    [_renderer settleMorphImmediately];
}

// progress 0 sits at -centerX, 1 at virtualWidth - centerX.
- (CGFloat)contentOffsetForProgress:(CGFloat)progress {
    return progress * [self virtualWidth] - self.bounds.size.width / 2;
}

- (CGFloat)progressForContentOffset:(CGFloat)x {
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return 0;
    }
    return (x + self.bounds.size.width / 2) / virtualWidth;
}

- (void)applyScrollAndProgress {
    [self syncContentOffsetToProgress];
    [self applyPlayedClip];
    [self drawRendererWindowForcing:NO];
    [self syncLoadingTrackToProgress];
}

// Playback's writes move the scroll; the finger's do not get overwritten.
- (void)syncContentOffsetToProgress {
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0 || self.isScrubbing) {
        return;
    }
    CGFloat x = [self contentOffsetForProgress:MAX(0.0, MIN(1.0, _progress))];
    if (fabs(_scroll.contentOffset.x - x) < 0.01) {
        return;
    }
    [self setContentOffsetX:x];
}

// TRAP: an explicit CATransaction here is a top-level one on the display
// link's tick, so every progress step committed the whole tree — layout
// included — a second time in its frame. A scroll view's own layer animates
// only inside an animation block, which this opts out of instead.
- (void)setContentOffsetX:(CGFloat)x {
    [UIView performWithoutAnimation:^{
        self->_scroll.contentOffset = CGPointMake(x, 0);
    }];
}

// TRAP: the park above declines while isScrubbing, and a cancelled scroll
// keeps isDragging/isTracking until the touch is delivered, as a pinch's own
// fingers keep isTracking. A reset and every pinch frame park here,
// unconditionally, or the content stays where the last gesture left it.
- (void)parkContentOffsetAtProgress {
    CGFloat x = [self contentOffsetForProgress:MAX(0.0, MIN(1.0, _progress))];
    // Also bounds the re-entry from scrollViewDidScroll:.
    if (fabs(_scroll.contentOffset.x - x) < 0.01) {
        return;
    }
    [self setContentOffsetX:x];
}

// What the played side spans: under a playhead line the whole waveform, the
// line alone marking the position. Progress can leave the unit range at track
// end or in a bounce, and the played side would reach past the track.
- (CGFloat)playedProgress {
    return _renderer.theme.playheadColor ? 1 : MAX(0.0, MIN(1.0, _progress));
}

// The playhead marker unless the theme draws a line. In CONTENT space, so the
// scroll carries it to the center and nothing here reads the offset.
//
// TRAP: no explicit transaction here or in the window's redraw: see
// setContentOffsetX:. Disabling actions on the implicit one nests the
// renderers' own transactions inside it.
- (void)applyPlayedClip {
    if (!self.waveform || !_renderer) {
        return;
    }
    [CATransaction setDisableActions:YES];
    [_renderer updateProgress:[self playedProgress] waveform:self.waveform.waveform];
    VibeTallyCount(waveform_progress);
}

// A margin around what the view shows, so a scroll moves pixels already
// drawn, and content far wider than the screen is never drawn whole. Half a
// view either side, or once a scroll leaves the window a whole view ahead and
// a quarter behind: playback then redraws after a view of travel, not half
// of one. None mid-pinch, since every pinch frame draws again. Every step
// style draws the same pixels for the same content wherever its window
// lands, so a redraw cannot be seen.
- (void)drawRendererWindowForcing:(BOOL)force {
    CGRect virtualBounds = [self virtualBounds];
    CGFloat width = self.bounds.size.width;
    if (!self.waveform || !_renderer || virtualBounds.size.width <= 0 || width <= 0) {
        return;
    }
    CGRect visible = CGRectIntersection(CGRectMake(_scroll.contentOffset.x, 0, width, virtualBounds.size.height),
                                        virtualBounds);
    if (!force && !CGRectIsNull(_renderWindow) &&
        (CGRectIsNull(visible) || CGRectContainsRect(_renderWindow, visible))) {
        return;
    }
    CGFloat before = _isPinching ? 0 : width / 2, after = before;
    if (!force && !_isPinching && !CGRectIsNull(_renderWindow) && !CGRectIsNull(visible)) {
        BOOL forward = CGRectGetMidX(visible) > CGRectGetMidX(_renderWindow);
        before = forward ? width / 4 : width;
        after = forward ? width : width / 4;
    }
    CGRect window = CGRectIntersection(CGRectMake(CGRectGetMinX(visible) - before, 0,
                                                  CGRectGetWidth(visible) + before + after, virtualBounds.size.height),
                                       virtualBounds);
    _renderWindow = CGRectIsNull(window) ? CGRectZero : window;
    [CATransaction setDisableActions:YES];
    // Wiggle keeps its loops through a zoom: it counts them at the resting
    // zoom while drawing across the zoomed width.
    _renderer.samplingWidth = width / kVibeWaveformDefaultZoomFraction;
    _renderer.renderRect = _renderWindow;
    [_renderer updateWaveform:virtualBounds progress:[self playedProgress] waveform:self.waveform.waveform];
    VibeTallyCount(waveform_window);
    [self requestDetailForWindow];
}

// Deep zoom's blocks: the ones the draw just lacked, a request at a time.
// A block the answer could not read is asked for again only when a later
// draw lacks it, so a file gone from disk cannot loop.
- (void)requestDetailForWindow {
    AudioWaveform *waveform = self.waveform.waveform;
    if (_detailRequested || !waveform
            || ![self.delegate respondsToSelector:@selector(waveformScrubberView:needsDetailBlocks:ofWaveform:)]) {
        return;
    }
    NSMutableIndexSet *wanted = [NSMutableIndexSet indexSet];
    for (int64_t block : waveform->detail().takeLackedBlocks()) {
        [wanted addIndex:(NSUInteger)block];
    }
    if (wanted.count == 0) {
        return;
    }
    _detailRequested = YES;
    [self.delegate waveformScrubberView:self needsDetailBlocks:wanted ofWaveform:self.waveform];
}

- (void)detailDidLoadForWaveform:(CodableAudioWaveform *)waveform {
    _detailRequested = NO;
    if (waveform != self.waveform) {
        return;
    }
    [self drawRendererWindowForcing:YES];
}
// The play position IS the view's center, so the line never moves: it follows
// only the theme, the layout and whether there is a waveform to mark.
static const CGFloat kPlayheadLineOvershoot = 8;

- (void)layoutPlayheadLine {
    VibeColor *color = self.waveform ? _renderer.theme.playheadColor : nil;
    if (!color && _playheadLine.hidden) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playheadLine.hidden = !color;
    if (color) {
        CGRect bounds = self.bounds;
        // The band is in the flipped host's y-up space and the line is not,
        // which an off-center band (Sonic Cirrus) shows.
        CGRect band = [_renderer seekHitBandForBounds:bounds];
        band.origin.y = bounds.size.height - CGRectGetMaxY(band);
        // A few points past the waveform at each end, as the widget's line
        // reaches past its strip.
        band = CGRectIntersection(CGRectInset(band, 0, -kPlayheadLineOvershoot), bounds);
        _playheadLine.backgroundColor = color.CGColor;
        _playheadLine.frame = VibePlayheadLineRect(bounds.size.width / 2, band,
                bounds.size.width, [self displayScale]);
    }
    [CATransaction commit];
}

#pragma mark - Progress

- (NSUInteger)progressBucket {
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)([self virtualWidth] * [self displayScale]));
    // TRAP: clamp before the cast. _progress can land outside the unit range at
    // track end, and a negative or overlarge double to NSUInteger is undefined.
    return static_cast<NSUInteger>(MAX(0.0, MIN(1.0, _progress)) * steps);
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    // Per device pixel of the virtual axis, as on the mac.
    NSUInteger p = [self progressBucket];
    if (_progressTracker != p) {
        _progressTracker = p;
        [self applyScrollAndProgress];
    }
}

- (CGFloat)progress {
    return _progress;
}

#pragma mark - Accessibility

// The mac view's contract. The element is the scrubber ITSELF, not its scroll
// view. A fraction, not seconds: the view knows no duration.
static const CGFloat kWaveformAccessibilityStep = 0.05;

- (BOOL)isAccessibilityElement {
    return YES;
}

- (UIAccessibilityTraits)accessibilityTraits {
    return self.isScrubbingEnabled ? UIAccessibilityTraitAdjustable
                                   : UIAccessibilityTraitNone;
}

- (NSString *)accessibilityLabel {
    return STR_A11Y_WAVEFORM;
}

- (NSString *)accessibilityValue {
    return [Formatters.sharedInstance percentString:_progress];
}

- (void)accessibilityIncrement {
    [self seekAccessibilityByDelta:kWaveformAccessibilityStep];
}

- (void)accessibilityDecrement {
    [self seekAccessibilityByDelta:-kWaveformAccessibilityStep];
}

// The position comes back through the owner's progress write, as for a scrub.
- (void)seekAccessibilityByDelta:(CGFloat)delta {
    if (!self.isScrubbingEnabled) {
        return;
    }
    CGFloat target = MAX(0.0, MIN(1.0, _progress + delta));
    if (target == _progress) {
        return;
    }
    [self.delegate waveformScrubberView:self didSeek:(float)target];
}

#pragma mark - Presentation states

- (void)cancelInteraction {
    // Drop the seek before disabling recognizers, which can send end callbacks.
    _seekPending = NO;
    _scrubHaptics = nil;
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _scroll.scrollEnabled = NO;
    _pinch.enabled = NO;
    // Cancellation need not deliver its recognizer callback synchronously.
    if (_isPinching) {
        [self endZoomGesture];
    }
    _scroll.scrollEnabled = self.waveform != nil;
    _pinch.enabled = YES;
    [self parkContentOffsetAtProgress];
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
}

- (void)resetWaveformContentState {
    [self discardRenderer];
    // An answer still out lands on a view showing nothing of it.
    _detailRequested = NO;
    [self cancelInteraction];
    self.waveform = nil;
    // Force the repaint even when the bucket is already 0.
    _progressTracker = NSUIntegerMax;
    self.progress = 0;
    // TRAP: the cancel above leaves isDragging set until the touch is
    // delivered, so the progress write can skip its park and leave a recycled
    // cell at the previous track's position.
    [self parkContentOffsetAtProgress];
}

- (void)setPlaybackLoading:(BOOL)loading {
    _playbackLoading = loading;
    if (loading) {
        [self showLoadingIndicator];
    }
    else {
        [self setLoadingProgress:-1];
    }
}

#pragma mark - Layout and appearance

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyVirtualGeometry];
    [self layoutPlayheadLine];
}

// Layout and the zoom both call this: a zoom moves the virtual width with the
// bounds unchanged. Each pinch frame draws again, from the zoom steps' fixed
// columns, so the picture stays sharp through the gesture.
- (void)applyVirtualGeometry {
    VibeSignpostBegin(waveform_geometry);
    CGRect virtualBounds = [self virtualBounds];
    BOOL sizeChanged = !CGSizeEqualToSize(_rendererHost.bounds.size, virtualBounds.size);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.frame = self.bounds;
    CGFloat centerX = self.bounds.size.width / 2;
    _scroll.contentInset = UIEdgeInsetsMake(0, centerX, 0, centerX);
    _scroll.contentSize = CGSizeMake(virtualBounds.size.width, self.bounds.size.height);
    _rendererHost.bounds = virtualBounds;
    [CATransaction commit];
    if (sizeChanged) {
        // The offset parks below at the new width, then the window follows it.
        _renderWindow = CGRectNull;
    }
    // Parked first, so a pinch frame with a seek pending draws once, where
    // it lands.
    if (_isPinching) {
        [self parkContentOffsetAtProgress];
    }
    [self applyScrollAndProgress];
    // The bucket is per pixel of the virtual width, which just moved; without
    // this every playback write during a pinch passes setProgress:'s gate.
    _progressTracker = [self progressBucket];
    if (sizeChanged) {
        [self layoutLoadingLayer];
        // Tells a trace which layout passes actually moved the width.
        VibeSignpostCount(waveform_resize);
    }
    VibeSignpostEnd(waveform_geometry);
}

- (void)traitsDidChange:(UITraitCollection *)previous {
    BOOL scaleChanged = previous.displayScale != self.traitCollection.displayScale;
    BOOL styleChanged = previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle;
    if (scaleChanged) {
        VibeApplyContentsScale(self.layer, [self displayScale]);
        [_renderer backingScaleDidChange];
        [self drawRendererWindowForcing:YES];
        [self layoutPlayheadLine];
    }
    if (styleChanged) {
        // Re-resolved, not just recolored: the theme is per appearance.
        [self applyResolvedTheme];
        [_loadingIndicator updateColorsForDark:self.isDark];
    }
}

#pragma mark - Showing a waveform

- (void)prepareForWaveformLoad {
    _playbackLoading = NO;
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    [self installRendererIfNeeded];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [self showWaveform:waveform animated:YES];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated {
    // A page brought back by a swipe is handed what it already shows.
    if ([self isShowingCompleteWaveform:waveform]) {
        return;
    }
    VibeSignpostBegin(waveform_delivery);
    // Per-page cells can hydrate without prepareForWaveformLoad.
    [self installRendererIfNeeded];
    BOOL arrival = !self.waveform;
    self.waveform = waveform;
    [self drawRendererWindowForcing:YES];
    if (!animated) {
        [_renderer settleMorphImmediately];
    }
    if (arrival) {
        // The picture ends the shimmer, not the data: the fill stays; see
        // hideLoadingShimmer.
        [self hideLoadingShimmer];
    }
    VibeSignpostEnd(waveform_delivery);
}

@end
