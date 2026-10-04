//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "WaveformRendererRegistry.h"
#import "LoadingIndicator.h"
#import "WaveformZoomMath.h"
#import "UIView+DarkMode.h"
#import "AppSettings.h"
#import "Formatters.h"
#import "PlatformColor.h"
#import "VibeStrings.h"

// Names the element the XCUITest driver pinches (XCUITest has no
// coordinate-based multi-touch); spelled the same in
// Tests/iOSDriver/VibeiOSDriverTests.m.
static NSString *const kWaveformScrubberIdentifier = @"waveform-scrubber";

// One rigid tick per point of scrub travel, so a slow scrub ratchets
// continuously; well under full intensity because it fires many times a
// second.
static const CGFloat kScrubTickSpacing = 1.0;
static const CGFloat kScrubTickIntensity = 0.55;

// TRAP: the spacing above is a distance, not a rate. A fast scrub crosses it
// every frame, and sustained over-requesting takes the Taptic Engine out for
// seconds past the gesture. This ceiling keeps a fast scrub a ratchet.
static const CFTimeInterval kScrubTickMinInterval = 1.0 / 28.0;

// How far a pinch's fingers may wander before the gesture counts as a scrub.
static const CGFloat kZoomScrubSlop = 12.0;

// How often a streaming load re-bakes: it delivers ~10 times a second, and a
// swap per delivery reads as flicker. Trailing, so the newest shape wins, and
// steady, so the picture fills in at one pace whatever the decode's.
static const NSTimeInterval kLoadBakeMinInterval = 0.4;

// How long a partial waveform waits for its load to complete before it shows.
// Most loads complete inside it and enter once, at their final heights; only
// a slow one shows partials and then the completion's grow.
static const NSTimeInterval kFirstPartialDelay = 0.5;

// A bitmap's entrance. The first onto an empty view grows from the midline;
// a complete one over a partial one grows from the partial's heights to its
// own, since Normalize raises the reference only for the whole track and the
// bars would jump taller. Every other install is an instant swap.
static const CFTimeInterval kArrivalGrowDuration = 0.3;
// A streaming load's newly decoded stretch grows up from the midline; the
// rest of the picture holds still. Under kLoadBakeMinInterval, so one reveal
// ends before the next swap. A steep ease in and out, so it reads as a snap
// rather than a drift.
static const CFTimeInterval kChunkGrowDuration = 0.2;
static const CFTimeInterval kCompletionGrowDuration = 0.35;

@interface WaveformScrubberView () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // contentSize is the virtual width; insets of half a view park both ends
    // under the center. Everything that scrolls is a sublayer of ITS layer;
    // the loading indicator stays in self.layer.
    UIScrollView            *_scroll;
    // The renderer only samples for the bake and is never shown: its layers
    // live here, hidden, at virtual size so its bar counts match the bitmap's.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
    // The palette a style without a fast bake is drawn in: the renderer's,
    // minus the playhead line, which this view draws itself.
    WaveformTheme           *_bakeTheme;
    NSString                *_styleIdentifier;
    NSString                *_themeSignature;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    LoadingIndicator *_loadingIndicator;
    // The span it was last placed across; see syncLoadingTrackToProgress.
    CGRect            _loadingTrackBounds;
    UIImpactFeedbackGenerator *_scrubHaptics;
    NSInteger               _lastTickBucket;
    CFTimeInterval          _lastTickTime;
    // So the seek commits once per gesture, not per delegate call.
    BOOL                    _seekPending;
    // Where the pending scrub began, so a pinch can tell a scrub from drift.
    CGFloat                 _scrubStartProgress;
    // The one picture, anchored at the midline, which the arrival grows from.
    // It is made of segments, each a stretch of the track drawn as the played
    // image up to the playhead over the unplayed one: one for the whole track,
    // three while a newly decoded stretch grows in (newSegmentFrom:to:).
    CALayer                 *_bakedHost;
    id                      _bakedPlayedImage;
    id                      _bakedUnplayedImage;
    float                   _bakedUnplayedOpacity;
    // Whether the standing bake drew a complete waveform.
    BOOL                    _bakedComplete;
    NSUInteger              _bakedEpoch;
    BOOL                    _animatesArrival;
    // How far the standing bitmap's decode reached, and the segment of the
    // newest stretch while it grows in.
    CGFloat                 _bakedDecodedFraction;
    CALayer                 *_revealLayer;
    // The theme's playhead line, hidden until a theme asks for it: fixed at
    // center in self.layer, since it is the content that moves.
    CALayer                 *_playheadLine;
    // Two ways to be stale. Every schedule bumps the request, so only the
    // newest pending timer bakes. A change of meaning — a reset, a palette, a
    // style, a scale — bumps the epoch, which a finished bake must match to
    // install; a bake overtaken by a newer streaming delivery still lands.
    NSUInteger              _bakeRequest;
    NSUInteger              _bakeEpoch;
    // One bake at a time; a request during one is rescheduled on completion.
    BOOL                    _bakeInFlight;
    BOOL                    _bakeWanted;
    // For the rate limit; 0 bakes at once.
    CFTimeInterval          _lastBakeAt;
    // When this load's first delivery came; 0 before it.
    CFTimeInterval          _firstDeliveryAt;
    CGFloat                 _visibleFraction;
    UIPinchGestureRecognizer *_pinch;
    BOOL                    _isPinching;
    CGFloat                 _pinchStartFraction;
    // The pinch-driven scrub's last centroid and its touch count; see
    // trackZoomGestureScrub:.
    CGFloat                 _zoomScrubLastX;
    NSUInteger              _zoomScrubTouches;
}

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
        return [WaveformTheme themeForIdentifier:settings.waveformTheme
                                          isDark:isDark
                                    artworkColor:self->_artworkThemeColor
                                    customPlayed:[settings waveformCustomPlayedColorForDark:isDark]
                                  customUnplayed:[settings waveformCustomUnplayedColorForDark:isDark]];
    };
    WaveformTheme *theme = resolve();
    // No well for it here: the appearance's contrast pole, the mac's default.
    if ([self drawsPlayheadLine]) {
        theme.playheadColor = isDark ? UIColor.whiteColor : UIColor.blackColor;
    }
    _renderer.theme = theme;
    _bakeTheme = resolve();
    [_renderer updateColors:isDark];
    [self layoutPlayheadLine];
    _themeSignature = [self themeSignature];
}

- (BOOL)drawsPlayheadLine {
    return [WaveformRendererRegistry drawsPlayheadLineForIdentifier:_styleIdentifier
                                                             chosen:AppSettings.sharedInstance.waveformPlayheadLine];
}

// Everything the resolution reads, in both appearances — including this page's
// artwork color, or a swipe onto a track with different art compares equal
// and keeps the previous track's palette.
- (NSString *)themeSignature {
    AppSettings *settings = AppSettings.sharedInstance;
    return [NSString stringWithFormat:@"%@|%d|%@|%@|%@|%@|%@", settings.waveformTheme,
            [self drawsPlayheadLine],
            VibeHexStringFromColor([settings waveformCustomPlayedColorForDark:YES]) ?: @"",
            VibeHexStringFromColor([settings waveformCustomUnplayedColorForDark:YES]) ?: @"",
            VibeHexStringFromColor([settings waveformCustomPlayedColorForDark:NO]) ?: @"",
            VibeHexStringFromColor([settings waveformCustomUnplayedColorForDark:NO]) ?: @"",
            VibeHexStringFromColor(_artworkThemeColor) ?: @""];
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

- (void)prepareForWaveformLoad {
    _playbackLoading = NO;
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    [self installRendererIfNeeded];
}

// A neighbor's prepared pixels can be installed before the page appears.
- (BOOL)showPreparedWaveform:(CodableAudioWaveform *)waveform
                  fromView:(WaveformScrubberView *)view {
    [self installRendererIfNeeded];
    if (!view || view.waveform != waveform || !view->_bakedHost || !view->_bakedComplete
            || view->_bakedEpoch != view->_bakeEpoch
            || !CGRectEqualToRect([self virtualBounds], [view virtualBounds])
            || [self displayScale] != [view displayScale] || self.isDark != view.isDark
            || ![_styleIdentifier isEqualToString:view->_styleIdentifier]
            || ![_themeSignature isEqualToString:view->_themeSignature]) {
        return NO;
    }
    if (self.waveform == waveform && _bakedHost && _bakedComplete) {
        return YES;
    }
    self.waveform = waveform;
    _animatesArrival = NO;
    _bakeRequest++;
    _bakeEpoch++;
    _bakeWanted = NO;
    [self installEnvelopeImage:(__bridge CGImageRef)view->_bakedPlayedImage
                unplayedImage:view->_bakedUnplayedOpacity == 1
                        ? (__bridge CGImageRef)view->_bakedUnplayedImage : nil
                        epoch:_bakeEpoch complete:YES normalizationGain:1 decodedFraction:1];
    return YES;
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [self showWaveform:waveform animated:YES];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated {
    // A page brought back by a swipe is handed what it already shows.
    if (waveform == self.waveform && _bakedHost && _bakedComplete) {
        return;
    }
    // Per-page cells can hydrate without prepareForWaveformLoad.
    [self installRendererIfNeeded];
    VibeSignpostBegin(waveform_delivery);
    self.waveform = waveform;
    _animatesArrival = animated;
    CFTimeInterval now = CACurrentMediaTime();
    if (_firstDeliveryAt == 0) {
        _firstDeliveryAt = now;
    }
    // The complete one as soon as it can be drawn; a first partial once its
    // load has had kFirstPartialDelay to complete; later partials at a steady
    // pace.
    NSTimeInterval delay = 0;
    if (!waveform.waveform->isComplete()) {
        delay = _bakedHost ? [self throttledBakeDelay]
                           : MAX(0, _firstDeliveryAt + kFirstPartialDelay - now);
    }
    [self scheduleEnvelopeBakeAfter:delay];
    VibeSignpostEnd(waveform_delivery);
}

// 0, or the rest of the window, so a burst collapses to one bake.
- (NSTimeInterval)throttledBakeDelay {
    CFTimeInterval since = CACurrentMediaTime() - _lastBakeAt;
    if (since >= kLoadBakeMinInterval) {
        return 0;
    }
    return kLoadBakeMinInterval - since;
}

#pragma mark - The bitmap

// TRAP: the picture is only ever this bitmap; never show the renderer's
// live tree. It is a multi-screen layer under a mask of thousands of rects,
// which the render server scan-converts on the CPU each frame it moves: a
// scrub over it ran at 30 Hz or less on a phone.

- (void)removeBakedWaveform {
    _bakeEpoch++;
    _bakeRequest++;
    _bakeWanted = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_bakedHost removeFromSuperlayer];
    _bakedHost = nil;
    _bakedPlayedImage = nil;
    _bakedUnplayedImage = nil;
    _revealLayer = nil;
    _bakedDecodedFraction = 0;
    [CATransaction commit];
}

- (void)scheduleEnvelopeBakeAfter:(NSTimeInterval)delay {
    _bakeRequest++;
    if (!self.waveform || !_renderer) {
        return;
    }
    NSUInteger request = _bakeRequest;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf bakeEnvelopeForRequest:request];
    });
}

// A finished bake installs while the epoch holds, even if a newer delivery
// arrived, and a request mid-bake waits rather than running beside it:
// discarding full-size pixel work per delivery was a large share of the app's
// CPU.
- (void)bakeEnvelopeForRequest:(NSUInteger)request {
    if (request != _bakeRequest || !self.waveform) {
        return;
    }
    if (_bakeInFlight) {
        _bakeWanted = YES;
        return;
    }
    CGSize size = [self virtualBounds].size;
    if (size.width <= 0 || size.height <= 0) {
        return;
    }
    _lastBakeAt = CACurrentMediaTime();
    AudioWaveformRenderer *renderer = _renderer;
    CGFloat scale = [self displayScale];
    // Past the texture ceiling a layer renders BLANK: a layout wide enough that
    // even the resting zoom overflows (the zoom floor keeps a pinch out) bakes
    // at reduced scale and stretches back.
    if (size.width * scale > kVibeMaxBakeImagePixels) {
        scale = MAX(kVibeMaxBakeImagePixels / size.width, 0.25);
    }
    CodableAudioWaveform *waveform = self.waveform;
    BOOL complete = waveform.waveform->isComplete();
    CGFloat normalizationGain = complete ? [renderer normalizationGainForWaveform:waveform.waveform] : 1;
    CGFloat decodedFraction = waveform.waveform->getDecodedFraction();
    // The fast bake samples on main, like updateWaveform:'s; only the pixel
    // work leaves. A style without one is drawn whole through the registry,
    // as the widget draws it: once all played, once all unplayed.
    NSData *samples = nil;
    NSString *style = _styleIdentifier;
    WaveformTheme *theme = _bakeTheme;
    BOOL dark = self.isDark;
    if (renderer.supportsEnvelopeBake) {
        renderer.samplingWidth = self.bounds.size.width / kVibeWaveformDefaultZoomFraction;
        VibeSignpostBegin(waveform_samples);
        samples = [renderer envelopeSamplesForWaveform:waveform.waveform];
        VibeSignpostEnd(waveform_samples);
    }
    NSUInteger epoch = _bakeEpoch;
    _bakeInFlight = YES;
    _bakeWanted = NO;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VibeSignpostBegin(waveform_bake);
        CGImageRef image, unplayedImage;
        if (samples) {
            image = [renderer newEnvelopeImageForSize:size scale:scale samples:samples];
            unplayedImage = [renderer newUnplayedEnvelopeImageForSize:size scale:scale samples:samples];
        }
        else {
            image = [WaveformRendererRegistry newImageForCodableWaveform:waveform identifier:style
                    pointSize:size scale:scale progress:1 dark:dark theme:theme
                    barDensity:1 barWidth:1 normalize:YES gainDB:0];
            unplayedImage = [WaveformRendererRegistry newImageForCodableWaveform:waveform identifier:style
                    pointSize:size scale:scale progress:0 dark:dark theme:theme
                    barDensity:1 barWidth:1 normalize:YES gainDB:0];
        }
        VibeSignpostEnd(waveform_bake);
        dispatch_async(dispatch_get_main_queue(), ^{
            WaveformScrubberView *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_bakeInFlight = NO;
                [strongSelf installEnvelopeImage:image unplayedImage:unplayedImage epoch:epoch
                                        complete:complete normalizationGain:normalizationGain
                                 decodedFraction:decodedFraction];
                if (strongSelf->_bakeWanted) {
                    strongSelf->_bakeWanted = NO;
                    [strongSelf scheduleEnvelopeBakeAfter:[strongSelf throttledBakeDelay]];
                }
            }
            CGImageRelease(image);
            CGImageRelease(unplayedImage);
            // Captured so a renderer outliving its view is released here, on
            // main: its dealloc tears down layers.
            (void)renderer;
        });
    });
}

// At the CURRENT geometry: a bitmap drawn for an older one is stretched to it
// (resize gravity) until the re-bake the change asked for lands, so a resize,
// a rotation or a pinch never blanks the strip.
- (void)placeBakedLayer:(CALayer *)host {
    CGFloat oldWidth = host.bounds.size.width;
    CGRect bounds = [self virtualBounds];
    host.bounds = bounds;
    host.position = CGPointMake(0, bounds.size.height / 2);
    for (CALayer *segment in host.sublayers) {
        CGFloat start = oldWidth > 0 ? segment.position.x / oldWidth : 0;
        CGFloat length = oldWidth > 0 ? segment.bounds.size.width / oldWidth : 1;
        segment.bounds = CGRectMake(0, 0, length * bounds.size.width, bounds.size.height);
        segment.position = CGPointMake(start * bounds.size.width, bounds.size.height / 2);
        segment.sublayers.firstObject.frame = segment.bounds;
    }
}

// [start, end) of the track, in the standing images. Anchored at the midline,
// so a reveal grows it from there.
- (CALayer *)newSegmentFrom:(CGFloat)start to:(CGFloat)end {
    return [self newSegmentFrom:start to:end played:_bakedPlayedImage
                       unplayed:_bakedUnplayedImage unplayedOpacity:_bakedUnplayedOpacity];
}

- (CALayer *)newSegmentFrom:(CGFloat)start to:(CGFloat)end played:(id)playedImage
                   unplayed:(id)unplayedImage unplayedOpacity:(float)unplayedOpacity {
    CGRect bounds = _bakedHost.bounds;
    CALayer *segment = [CALayer layer];
    segment.anchorPoint = CGPointMake(0, 0.5);
    segment.bounds = CGRectMake(0, 0, (end - start) * bounds.size.width, bounds.size.height);
    segment.position = CGPointMake(start * bounds.size.width, bounds.size.height / 2);
    CALayer *unplayed = [CALayer layer];
    unplayed.frame = segment.bounds;
    unplayed.contents = unplayedImage;
    unplayed.opacity = unplayedOpacity;
    unplayed.contentsRect = CGRectMake(start, 0, end - start, 1);
    [segment addSublayer:unplayed];
    CALayer *played = [CALayer layer];
    played.actions = @{@"bounds": NSNull.null, @"position": NSNull.null,
                       @"contentsRect": NSNull.null};
    played.anchorPoint = CGPointZero;
    played.position = CGPointZero;
    played.contents = playedImage;
    [segment addSublayer:played];
    [_bakedHost addSublayer:segment];
    return segment;
}
- (void)installEnvelopeImage:(CGImageRef)image unplayedImage:(nullable CGImageRef)unplayedImage
                       epoch:(NSUInteger)epoch complete:(BOOL)complete
           normalizationGain:(CGFloat)normalizationGain
             decodedFraction:(CGFloat)decodedFraction {
    if (!image || epoch != _bakeEpoch || !self.waveform) {
        return;
    }
    VibeSignpostBegin(waveform_install);
    BOOL arrival = !_bakedHost;
    CGFloat revealFrom = _bakedDecodedFraction;
    _revealLayer = nil;
    BOOL completes = _bakedHost && !_bakedComplete && complete;
    BOOL reveals = !arrival && !_isPinching && decodedFraction > revealFrom;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // TRAP: drop the standing bitmap first, or it stays in the scroll's tree
    // for the life of the view. Never fade one picture over another: the
    // waveforms are translucent, so the pair drew brighter than either for the
    // fade and the end of it dimmed in one frame.
    [_bakedHost removeFromSuperlayer];
    // The undecoded tail of a reveal is cut from the picture being replaced.
    id previousPlayed = _bakedPlayedImage;
    id previousUnplayed = _bakedUnplayedImage;
    float previousOpacity = _bakedUnplayedOpacity;
    _bakedPlayedImage = (__bridge id)image;
    _bakedUnplayedImage = (__bridge id)(unplayedImage ?: image);
    // No unplayed bake: the played bitmap dimmed. Otherwise the unplayed
    // side's own, already at its resting alphas.
    _bakedUnplayedOpacity = (float)(unplayedImage ? 1 : [_renderer unplayedOverPlayedOpacity]);
    // No geometryFlipped here: the bake draws in CG's y-up space, whose top
    // row lands at the layer's top.
    _bakedHost = [CALayer layer];
    _bakedHost.anchorPoint = CGPointMake(0, 0.5);
    [self placeBakedLayer:_bakedHost];
    if (reveals) {
        [self revealDecodedFrom:revealFrom to:decodedFraction tailPlayed:previousPlayed
                   tailUnplayed:previousUnplayed tailUnplayedOpacity:previousOpacity];
    }
    else {
        [self newSegmentFrom:0 to:1];
    }
    [_scroll.layer insertSublayer:_bakedHost above:_rendererHost];
    // TRAP: crop the played side inside this transaction. Called from a block
    // on main, it is top-level and commits at once, and a played layer left at
    // zero width for that frame drew the whole track unplayed: on a slow load
    // the played side blinked at every swap.
    [self applyPlayedClip];
    _bakedComplete = complete;
    _bakedEpoch = epoch;
    if (arrival) {
        // The picture ends the shimmer, not the data: until it lands the
        // strip would be empty. The fill stays; see hideLoadingShimmer.
        [self hideLoadingShimmer];
    }
    if (arrival && _animatesArrival) {
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        grow.fromValue = @0;
        grow.toValue = @1;
        grow.duration = kArrivalGrowDuration;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_bakedHost addAnimation:grow forKey:@"arrival"];
    }
    else if (completes && normalizationGain > 1.001) {
        // Over the last stretch's own reveal, which it carries up with it.
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        grow.fromValue = @(1 / normalizationGain);
        grow.toValue = @1;
        grow.duration = kCompletionGrowDuration;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_bakedHost addAnimation:grow forKey:@"completionGrow"];
    }
    _bakedDecodedFraction = decodedFraction;
    [CATransaction commit];
    [self applyScrollAndProgress];
    VibeSignpostEnd(waveform_install);
}
// Inside the install's transaction: the picture as three segments for the
// reveal's length — before the new stretch, the stretch growing up from the
// midline, and the undecoded rest — then one again. No mask, so no offscreen
// pass, and each segment crops its own played side, so the stretch grows the
// same on either side of the playhead.
//
// TRAP: every stretch outside the new one must stay drawn. Cropping one layer
// at the old edge hid the undecoded midline for each reveal, and it blinked at
// every swap; growing only the unplayed side popped a stretch the playhead had
// passed.
- (void)revealDecodedFrom:(CGFloat)from to:(CGFloat)to tailPlayed:(id)tailPlayed
                tailUnplayed:(id)tailUnplayed tailUnplayedOpacity:(float)tailUnplayedOpacity {
    if (from > 0) {
        [self newSegmentFrom:0 to:from];
    }
    // TRAP: everything past the old edge comes from the PREVIOUS picture,
    // where it is all midline. A drawn bar is wider than a chunk and straddles
    // the decoded edge, so in the new picture the edge bar's sliver lies past
    // it: cut from there, it stood at full height while the stretch grew.
    // Padding the stretch past its edges instead regrew bars already shown,
    // and the stretch no longer fit where it belonged.
    if (to < 1) {
        [self newSegmentFrom:to to:1 played:tailPlayed unplayed:tailUnplayed
             unplayedOpacity:tailUnplayedOpacity];
    }
    // TRAP: under the stretch, the previous picture only while the stretch is
    // near a hairline, which smooth outlines (3-Band) do not draw at all, so
    // the midline had a gap there. Left for the whole grow, its bright midline
    // and the cliff at its old edge showed through the translucent stretch.
    CALayer *underlay = [self newSegmentFrom:from to:to played:tailPlayed unplayed:tailUnplayed
                             unplayedOpacity:tailUnplayedOpacity];
    underlay.opacity = 0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = kChunkGrowDuration / 2;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [underlay addAnimation:fade forKey:@"underlayFade"];
    CALayer *reveal = [self newSegmentFrom:from to:to];
    _revealLayer = reveal;
    // Set before the animations, which it then waits for: the last stretch's
    // and, at completion, the whole picture's.
    __weak WaveformScrubberView *weakSelf = self;
    [CATransaction setCompletionBlock:^{
        [weakSelf finishRevealOf:reveal];
    }];
    // From a hairline, not from nothing: at zero the stretch left a gap in
    // the midline it grows out of.
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
    grow.fromValue = @(MIN(1.0, 1 / MAX(1.0, _bakedHost.bounds.size.height * [self displayScale])));
    grow.toValue = @1;
    grow.duration = kChunkGrowDuration;
    grow.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.7f :0.0f :0.3f :1.0f];
    [reveal addAnimation:grow forKey:@"chunkGrow"];
}
// A stale reveal is a no-op: a newer install or a reset replaced it.
- (void)finishRevealOf:(CALayer *)reveal {
    if (!reveal || reveal != _revealLayer) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _revealLayer = nil;
    for (CALayer *segment in [_bakedHost.sublayers copy]) {
        [segment removeFromSuperlayer];
    }
    [self newSegmentFrom:0 to:1];
    [self applyPlayedClip];
    [CATransaction commit];
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

- (void)showLoadingIndicator {
    if (_loadingIndicator) {
        return;
    }
    if (!self.waveform) {
        [self resetWaveformContentState];
    }
    _loadingIndicator = [[LoadingIndicator alloc]
            initInLayer:self.layer
                  style:VibeLoadingIndicatorStyleWaveform
                 isDark:self.isDark
          contentsScale:[self displayScale]];
    [self layoutLoadingLayer];
}

// The span the track's content occupies, not the view's width: the off-track
// space stays empty. The full bounds before layout.
- (CGRect)loadingTrackBounds {
    CGFloat width = self.bounds.size.width;
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return self.bounds;
    }
    CGFloat centerX = width / 2;
    CGFloat progress = MAX(0.0, MIN(1.0, _progress));
    CGFloat left = MAX(0.0, centerX - progress * virtualWidth);
    CGFloat right = MIN(width, centerX + (1 - progress) * virtualWidth);
    if (right <= left) {
        return self.bounds;
    }
    return CGRectMake(left, 0, right - left, self.bounds.size.height);
}

- (void)layoutLoadingLayer {
    _loadingTrackBounds = [self loadingTrackBounds];
    [_loadingIndicator layoutInBounds:_loadingTrackBounds];
}

// Follows the playhead: showLoadingIndicator runs at progress 0, and the
// shell's next tick restores the real position.
//
// TRAP: keep the rect test. This is the one relayout that can land
// mid-download, and a duration-0 relayout snaps an easing fill to its target;
// while the provider materializes the file progress is parked, so the test
// declines.
- (void)syncLoadingTrackToProgress {
    if (!_loadingIndicator || CGRectEqualToRect([self loadingTrackBounds], _loadingTrackBounds)) {
        return;
    }
    [self layoutLoadingLayer];
}

// Not the fill: a disk-cached waveform can land while the provider is still
// materializing the audio, and the fill is the only sign of that. It comes
// down with its monitor, via setLoadingProgress:-1.
- (void)hideLoadingShimmer {
    if (_playbackLoading) {
        return;
    }
    if (![_loadingIndicator endSweepKeepingFill]) {
        [self hideLoadingIndicator];
    }
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

- (void)setLoadingProgress:(float)fraction {
    if (fraction >= 0 && !_loadingIndicator) {
        [self showLoadingIndicator];
    }
    _loadingTrackBounds = [self loadingTrackBounds];
    [_loadingIndicator setProgress:fraction inBounds:_loadingTrackBounds];
    if (_bakedHost) {
        [self hideLoadingShimmer];
    }
}

#pragma mark - Touch scrubbing

// UIKit's direct manipulation; the seek commits once the content stops. A
// cancelled drag just stops; the next progress push restores the position.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (_isPinching) {
        // The pan still moves the offset under a pinch; park it rather than
        // reading a position out of it, or the waveform slides off center.
        [self parkContentOffsetAtProgress];
        [self applyPlayedClip];
        return;
    }
    if (self.isScrubbing) {
        _progress = MAX(0.0, MIN(1.0, [self progressForContentOffset:scrollView.contentOffset.x]));
        _progressTracker = [self progressBucket];
        [self.delegate waveformScrubberView:self didScrubToProgress:_progress];
        [self emitScrubTickIfNeeded];
    }
    [self applyPlayedClip];
}

// Shared with the pinch's scrub, so a gesture changing hands keeps its ratchet.
- (void)emitScrubTickIfNeeded {
    NSInteger bucket = [self tickBucket];
    if (bucket == _lastTickBucket) {
        return;
    }
    _lastTickBucket = bucket;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastTickTime >= kScrubTickMinInterval) {
        _lastTickTime = now;
        [_scrubHaptics impactOccurredWithIntensity:kScrubTickIntensity];
        [_scrubHaptics prepare];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (_isPinching) {
        // The pinch's own fingers can start the pan late; the pinch owns the
        // gesture, and decides for itself whether it scrubs.
        return;
    }
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
    // A drag that catches a coast continues that scrub.
    if (!_seekPending) {
        _scrubStartProgress = _progress;
    }
    _seekPending = YES;
    [self beginScrubFeedback];
    _lastTickTime = 0;
}

// Shared with the pinch's scrub, which starts past its slop.
- (void)beginScrubFeedback {
    if (!_scrubHaptics) {
        _scrubHaptics = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleRigid];
    }
    [_scrubHaptics prepare];
    _lastTickBucket = [self tickBucket];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self endScrub];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self endScrub];
}

// TRAP: a scrub seeks only when its gesture ends — here, or endZoomGesture for
// a pinch. A seek to 1.0 mid-gesture finishes the track and auto-advances
// with the finger still down, and isDecelerating is YES during a drag, so no
// "still moving" test separates a coast from a finger.
- (void)endScrub {
    if (_isPinching) {
        // TRAP: the pan dies mid-gesture on a touch-count change. Finishing
        // here would seek where the finger no longer is and release the pager
        // under a live drag; endZoomGesture settles all of it.
        return;
    }
    [self commitScrubSeek];
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
}

- (void)commitScrubSeek {
    if (!_seekPending) {
        return;
    }
    _seekPending = NO;
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, _progress))];
}

- (NSInteger)tickBucket {
    return (NSInteger)floor(_progress * [self virtualWidth] / kScrubTickSpacing);
}

// The scroll's bounds origin IS the content offset, so a location in its
// space is already a content x.
- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (!self.waveform || tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return;
    }
    CGFloat p = [tap locationInView:_scroll].x / virtualWidth;
    // Stop a coast, or it commits a second seek over this one; stopping does
    // not reliably call scrollViewDidEndDecelerating:, so release the pager
    // hold here.
    BOOL wasScrubbing = self.isScrubbing || _seekPending;
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _seekPending = NO;
    _scrubHaptics = nil;
    if (wasScrubbing) {
        [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
    }
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, p))];
}

#pragma mark - Pinch to zoom

// Zoom anchors at the playhead for free: re-parking the offset after a width
// change opens the picture about the center. The fraction is written LIVE, so
// every reader of virtualWidth stays correct; only the bake is deferred.

// TRAP: without this a pinch cannot START during a scrub: the scroll's pan has
// already recognized, and by default one gesture belongs to one recognizer.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return recognizer == _pinch && other == _scroll.panGestureRecognizer;
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    switch (pinch.state) {
        case UIGestureRecognizerStateBegan:
            if (self.waveform) {
                [self beginZoomGesture];
            }
            break;
        case UIGestureRecognizerStateChanged:
            if (_isPinching) {
                if (pinch.numberOfTouches >= 2 && pinch.scale > 0) {
                    // Pinch open is zoom IN. Clamped to the EFFECTIVE floor, so
                    // the gesture stops where the picture does.
                    self.visibleFraction = VibeWaveformClampVisibleFraction(
                            _pinchStartFraction / pinch.scale, [self minimumVisibleFraction]);
                }
                [self trackZoomGestureScrub:pinch];
                [self parkContentOffsetAtProgress];
            }
            break;
        default:
            if (_isPinching) {
                [self endZoomGesture];
            }
            break;
    }
}

// TRAP: UIScrollView's pan ENDS on any touch-count change, and an ended
// recognizer cannot begin again for a touch already down, while the pinch
// stays in Changed with one finger left. So from its first frame the pinch
// carries the gesture, and this moves the track under the remaining finger.
// Only ONE touch scrubs; with two the centroid is the zoom's anchor.
- (void)trackZoomGestureScrub:(UIPinchGestureRecognizer *)pinch {
    CGFloat x = [pinch locationInView:self].x;
    NSUInteger touches = pinch.numberOfTouches;
    CGFloat virtualWidth = [self virtualWidth];
    // Re-anchor on a touch-count change, or the 2->1 centroid jump scrubs.
    if (touches == 1 && touches == _zoomScrubTouches && virtualWidth > 0) {
        // TRAP: the finger left behind as a pinch lifts always wobbles, and
        // any movement here seeks. Until the slop, the last x stays the
        // anchor; past it the scrub starts where the finger is.
        if (!_seekPending) {
            if (fabs(x - _zoomScrubLastX) < kZoomScrubSlop) {
                return;
            }
            _seekPending = YES;
            _zoomScrubLastX = x;
            [self beginScrubFeedback];
        }
        CGFloat delta = (x - _zoomScrubLastX) / virtualWidth;
        CGFloat next = MAX(0.0, MIN(1.0, _progress - delta));
        if (next != _progress) {
            _progress = next;
            _progressTracker = [self progressBucket];
            [self.delegate waveformScrubberView:self didScrubToProgress:_progress];
            [self emitScrubTickIfNeeded];
        }
    }
    _zoomScrubLastX = x;
    _zoomScrubTouches = touches;
}

- (void)beginZoomGesture {
    _isPinching = YES;
    _pinchStartFraction = _visibleFraction;
    _zoomScrubLastX = [_pinch locationInView:self].x;
    _zoomScrubTouches = _pinch.numberOfTouches;
    // Stop a coast. A real scrub's pending seek commits on lift; the drift of
    // two fingers landing is no scrub and hands the position back to playback.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    if (_seekPending
            && fabs(_progress - _scrubStartProgress) * [self virtualWidth] < kZoomScrubSlop) {
        _seekPending = NO;
        _progress = _scrubStartProgress;
        _progressTracker = [self progressBucket];
    }
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
}

- (void)endZoomGesture {
    // Stop a coast the dying pan started, while the flag still routes its
    // scroll to the park: let run, scrollViewDidScroll: would read a position
    // out of it that no seek follows.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _isPinching = NO;
    // The bitmap is stretched and soft: re-bake at the zoom it landed on.
    [self scheduleEnvelopeBakeAfter:0];
    [self parkContentOffsetAtProgress];
    // The whole gesture's end; endScrub declined all of this.
    [self commitScrubSeek];
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
    [self.delegate waveformScrubberView:self didChangeVisibleFraction:_visibleFraction];
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
    if (sizeChanged) {
        _bakeEpoch++;
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
