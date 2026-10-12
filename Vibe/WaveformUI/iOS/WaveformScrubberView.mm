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
    _rendererHost.hidden = YES;
    [_scroll.layer addSublayer:_rendererHost];

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
// swipe.
- (void)setWaveform:(CodableAudioWaveform *)waveform {
    _waveform = waveform;
    _scroll.scrollEnabled = (waveform != nil);
    [self layoutPlayheadLine];
}

- (BOOL)isAnimatingWaveformArrival {
    return [_bakedHost animationForKey:@"arrival"] != nil;
}

- (BOOL)isShowingBakedWaveform {
    return _bakedHost != nil;
}

- (BOOL)isPinching {
    return _isPinching;
}

- (NSUInteger)bakeRequestCount {
    return _bakeRequest;
}

- (BOOL)seekPending {
    return _seekPending;
}

- (BOOL)isShowingLoadingIndicator {
    return _loadingIndicator != nil;
}

- (BOOL)isShowingCompleteWaveform:(CodableAudioWaveform *)waveform {
    return waveform == self.waveform && _bakedHost && _bakedComplete;
}

#pragma mark - Zoom

- (CGFloat)displayScale {
    return VibeBackingScaleOrDefault(self.traitCollection.displayScale);
}

// Moves with the view size and display scale, which is why the request is
// kept apart from what is drawn.
- (CGFloat)minimumVisibleFraction {
    return VibeWaveformMinimumVisibleFraction(self.bounds.size.width,
                                              self.bounds.size.height,
                                              [self displayScale]);
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
    // A request the floor swallows costs no layout.
    if ([self effectiveVisibleFraction] != previous) {
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

// The one resolution site on this view.
- (void)applyResolvedTheme {
    if (!_renderer) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL isDark = self.isDark;
    WaveformTheme *(^resolve)(void) = ^WaveformTheme *{
        return [WaveformTheme themeForSettings:settings widget:NO isDark:isDark artworkColor:self->_artworkThemeColor];
    };
    WaveformTheme *theme = resolve();
    // No well for it here: the appearance's contrast pole, the mac's default.
    if ([self drawsPlayheadLine]) {
        theme.playheadColor = isDark ? UIColor.whiteColor : UIColor.blackColor;
    }
    _renderer.theme = theme;
    _bakeTheme = resolve();
    [_renderer updateColors:isDark];
    // Geometry, not color, but it changes as these settings do, and the
    // signature that re-bakes and keys the bake store has to carry it.
    _renderer.centered = [settings waveformCenteredForWidget:NO];
    [self layoutPlayheadLine];
    _themeSignature = [self themeSignature];
}

- (BOOL)drawsPlayheadLine {
    return [WaveformRendererRegistry drawsPlayheadLineForIdentifier:_styleIdentifier
                                                             chosen:[AppSettings.sharedInstance waveformPlayheadLineForWidget:NO]];
}

// The resolved palette in both appearances. This page's artwork color counts
// only where the theme reads it. Under album_art a swipe onto a track with
// different art re-bakes, and under any other theme late art re-bakes
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
    // The old palette stays up until the recolored bitmap lands.
    _bakeEpoch++;
    [self applyResolvedTheme];
    [self scheduleEnvelopeBakeAfter:0];
}


- (void)syncWaveformStyle {
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    if (!_renderer || [style isEqualToString:_styleIdentifier]) {
        return;
    }
    // The outgoing style's bitmap stays up until the new one lands.
    _bakeEpoch++;
    _renderer = nil;
    [self installRendererIfNeeded];
    [self scheduleEnvelopeBakeAfter:0];
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
// end or in a bounce, and an out-of-unit contentsRect smears the bake's edge
// pixels.
- (CGFloat)playedProgress {
    return _renderer.theme.playheadColor ? 1 : MAX(0.0, MIN(1.0, _progress));
}

// The playhead marker unless the theme draws a line. In CONTENT space, so the
// scroll carries it to the center and nothing here reads the offset.
- (void)applyPlayedClip {
    CGFloat width = _bakedHost.bounds.size.width;
    if (width <= 0) {
        return;
    }
    // Its actions are off, so no transaction: see setContentOffsetX:.
    CGFloat progress = [self playedProgress];
    CGFloat height = _bakedHost.bounds.size.height;
    for (CALayer *segment in _bakedHost.sublayers) {
        CGFloat start = segment.position.x / width;
        CGFloat end = start + segment.bounds.size.width / width;
        CGFloat cut = MAX(start, MIN(end, progress));
        CALayer *played = segment.sublayers.lastObject;
        played.bounds = CGRectMake(0, 0, (cut - start) * width, height);
        played.contentsRect = CGRectMake(start, 0, cut - start, 1);
    }
    VibeTallyCount(waveform_progress_baked);
}
// The play position IS the view's center, so the line never moves: it follows
// only the theme, the layout and whether there is a waveform to mark.
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
    [self removeBakedWaveform];
    // The new track's first bake must not wait on the old track's rate limit.
    _lastBakeAt = 0;
    _firstDeliveryAt = 0;
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
// bounds unchanged.
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
    // A pinch frame or a resize STRETCHES the bitmap (soft until the re-bake)
    // rather than blanking it: three property writes.
    // A reveal's crop and stretch are in the old geometry: land it first.
    [self finishRevealOf:_revealLayer];
    if (_bakedHost) {
        [self placeBakedLayer:_bakedHost];
    }
    [CATransaction commit];
    [self applyScrollAndProgress];
    // The bucket is per pixel of the virtual width, which just moved; without
    // this every playback write during a pinch passes setProgress:'s gate.
    _progressTracker = [self progressBucket];
    // No epoch bump: a bake landing for the old size is right for that size,
    // stays up stretched, and the one asked for here follows it.
    if (sizeChanged) {
        // A pinch re-bakes once, on release (endZoomGesture).
        if (!_isPinching) {
            [self scheduleEnvelopeBakeAfter:0];
        }
        [self layoutLoadingLayer];
        // Tells a trace which layout passes actually moved the width.
        VibeSignpostCount(waveform_resize);
    }
    VibeSignpostEnd(waveform_geometry);
}

- (void)traitsDidChange:(UITraitCollection *)previous {
    BOOL scaleChanged = previous.displayScale != self.traitCollection.displayScale;
    BOOL styleChanged = previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle;
    if (!scaleChanged && !styleChanged) {
        return;
    }
    // The standing bitmap stays up until the redrawn one lands.
    _bakeEpoch++;
    if (scaleChanged) {
        VibeApplyContentsScale(self.layer, [self displayScale]);
        [_renderer backingScaleDidChange];
        // The scale moves the zoom floor with the bounds unchanged, and no
        // layout pass follows.
        [self applyVirtualGeometry];
        [self layoutPlayheadLine];
    }
    if (styleChanged) {
        // Re-resolved, not just recolored: the theme is per appearance.
        [self applyResolvedTheme];
        [_loadingIndicator updateColorsForDark:self.isDark];
    }
    [self scheduleEnvelopeBakeAfter:0];
}

@end
