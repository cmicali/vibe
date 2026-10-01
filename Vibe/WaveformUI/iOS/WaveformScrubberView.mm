//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "DetailedAudioWaveformRenderer.h"
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

// Past the morph's ~0.2s ease, so the swap to the bitmap lands on identical
// pixels.
static const NSTimeInterval kEnvelopeBakeDelay = 0.6;

// How often a settled delivery may re-bake: a streaming decode delivers ~10
// times a second and three pager cells may be baking. Trailing, so the newest
// shape always wins.
static const NSTimeInterval kLoadBakeMinInterval = 0.25;

@interface WaveformScrubberView () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // contentSize is the virtual width; insets of half a view park both ends
    // under the center. Everything that scrolls is a sublayer of ITS layer;
    // the loading indicator stays in self.layer.
    UIScrollView            *_scroll;
    // geometryFlipped gives the shared renderers the mac's y-up space. Virtual
    // size, at content origin.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
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
    // The settled fast path: unplayed full width, played on top cropped by
    // contentsRect. Non-nil _bakedHost means _rendererHost is hidden.
    CALayer                 *_bakedHost;
    CALayer                 *_bakedUnplayed;
    CALayer                 *_bakedPlayed;
    // Two ways to be stale. Every schedule bumps the request, so only the
    // newest pending timer bakes. Only a teardown (the picture changing
    // meaning) bumps the epoch, which a finished bake must match to install;
    // a bake overtaken by a newer streaming delivery still lands.
    NSUInteger              _bakeRequest;
    NSUInteger              _bakeEpoch;
    // One bake at a time; a request during one is rescheduled on completion.
    BOOL                    _bakeInFlight;
    BOOL                    _bakeWanted;
    // For the rate limit; 0 bakes at once.
    CFTimeInterval          _lastBakeAt;
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
    [_scroll.layer addSublayer:_rendererHost];

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
    _renderer.theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                 isDark:self.isDark
                                           artworkColor:_artworkThemeColor
                                           customPlayed:[settings waveformCustomPlayedColorForDark:self.isDark]
                                         customUnplayed:[settings waveformCustomUnplayedColorForDark:self.isDark]];
    [_renderer updateColors:self.isDark];
    _themeSignature = [self themeSignature];
}

// Everything the resolution reads, in both appearances — including this page's
// artwork color, or a swipe onto a track with different art compares equal
// and keeps the previous track's palette.
- (NSString *)themeSignature {
    AppSettings *settings = AppSettings.sharedInstance;
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@", settings.waveformTheme,
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
    // The bake carries the old palette. No morph to wait out, so no delay.
    [self teardownBakedWaveform];
    [self applyResolvedTheme];
    [self applyScrollAndProgress];
    [self scheduleEnvelopeBakeAfter:0];
}


- (void)syncWaveformStyle {
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    if (!_renderer || [style isEqualToString:_styleIdentifier]) {
        return;
    }
    // Dropping the renderer removes its layers; the bake is the outgoing
    // style's picture. The bars land settled, so re-bake on the next turn.
    [self teardownBakedWaveform];
    _renderer = nil;
    [self installRendererIfNeeded];
    [self drawWaveformSettled];
    [self scheduleEnvelopeBakeAfter:0];
}

- (void)drawWaveform {
    _renderer.samplingWidth = self.bounds.size.width / kVibeWaveformDefaultZoomFraction;
    [_renderer updateWaveform:[self virtualBounds] progress:_progress waveform:self.waveform.waveform];
    [self applyScrollAndProgress];
}

// Landed rather than eased: a reset here is a recycled pager cell emptied
// off-screen, and an ease nobody watches is charged to the swipe.
- (void)drawWaveformSettled {
    [self drawWaveform];
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.contentOffset = CGPointMake(x, 0);
    [CATransaction commit];
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.contentOffset = CGPointMake(x, 0);
    [CATransaction commit];
}

// The only playhead marker. In CONTENT space, so the scroll carries it to the
// center and nothing here reads the offset.
- (void)applyPlayedClip {
    CGFloat virtualWidth = [self virtualWidth];
    if (!_renderer || virtualWidth <= 0) {
        return;
    }
    // Progress can leave the unit range at track end or in a bounce, and an
    // out-of-unit contentsRect smears the bake's edge pixels.
    CGFloat progress = MAX(0.0, MIN(1.0, _progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_bakedHost) {
        _bakedPlayed.bounds = CGRectMake(0, 0, progress * virtualWidth, _bakedHost.bounds.size.height);
        _bakedPlayed.contentsRect = CGRectMake(0, 0, progress, 1);
        VibeTallyCount(waveform_progress_baked);
    }
    else {
        [_renderer updateProgress:progress waveform:self.waveform.waveform];
        // The branches cost alike here and not in the render server, so which
        // one a frame took is the measurement.
        VibeTallyCount(waveform_progress_live);
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

- (void)resetWaveformContentState {
    [self teardownBakedWaveform];
    // The new track's first bake must not wait on the old track's rate limit.
    _lastBakeAt = 0;
    // Stop a coast, then drop the waveform, which disables the scroll and
    // cancels any drag: a gesture must not straddle a track change.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _seekPending = NO;
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
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
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    [self installRendererIfNeeded];
    [self drawWaveformSettled];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [self showWaveform:waveform animated:YES];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated {
    // Data ends the shimmer, not the open landing (the decode may still be
    // streaming). The fill stays; see hideLoadingShimmer.
    [self hideLoadingShimmer];
    // Per-page cells can hydrate without prepareForWaveformLoad.
    [self installRendererIfNeeded];
    VibeSignpostBegin(waveform_delivery);
    // Ease only from nothing: the delivery completing a STREAMING decode asks
    // for an ease, but would only spring its trailing zeroed chunks up, at the
    // cost of the bake and a run of full-view rebuilds.
    BOOL ease = animated && self.waveform == nil;
    self.waveform = waveform;
    if (ease) {
        // The morph is a live-tree surface: the bake comes down so it shows.
        [self teardownBakedWaveform];
        [self drawWaveform];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
    else {
        // TRAP: do NOT tear the bake down here. With no ease to reveal, the
        // bitmap is a fractionally stale picture of the same waveform; a
        // teardown per delivery (~10 a second) would unhide the live tree and
        // bump the epoch that discards the bake in flight, so a streaming load
        // would never leave the live tree. The hidden live tree is still
        // brought up to date for whatever unhides it next.
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:[self throttledBakeDelay]];
    }
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

#pragma mark - Settled bitmap fast path

// The live tree's shape mask covers the whole virtual layer, and a masked
// group re-composites offscreen on every scroll frame; once settled the
// picture is one bitmap and a frame is texture translation. A reset, an eased
// delivery, or a geometry or trait change tears the bake down; a non-eased
// delivery leaves it standing (showWaveform:animated:).

- (void)teardownBakedWaveform {
    _bakeEpoch++;
    _bakeRequest++;
    _bakeWanted = NO;
    if (!_bakedHost) {
        return;
    }
    // Actions disabled, or unhiding the live tree fades and blanks the
    // waveform for a frame.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_bakedHost removeFromSuperlayer];
    _bakedHost = nil;
    _bakedUnplayed = nil;
    _bakedPlayed = nil;
    _rendererHost.hidden = NO;
    [CATransaction commit];
}

- (void)scheduleEnvelopeBakeAfter:(NSTimeInterval)delay {
    _bakeRequest++;
    // Not a kind-of test: Basic is a Detailed subclass that cannot bake.
    if (!self.waveform || !_renderer.supportsEnvelopeBake) {
        return;
    }
    NSUInteger request = _bakeRequest;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf bakeEnvelopeForRequest:request];
    });
}

// A streaming load schedules a bake per delivery. A finished bake installs
// while the epoch holds, even if a newer delivery arrived, and a request
// mid-bake waits rather than running beside it: discarding full-size pixel
// work per delivery was a large share of the app's CPU.
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
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)_renderer;
    CGFloat scale = [self displayScale];
    // Past the texture ceiling a layer renders BLANK: a layout wide enough that
    // even the resting zoom overflows (the zoom floor keeps a pinch out) bakes
    // at reduced scale and stretches back; below 1x, stay on the live tree.
    if (size.width * scale > kVibeMaxBakeImagePixels) {
        scale = kVibeMaxBakeImagePixels / size.width;
        if (scale < 1) {
            return;
        }
    }
    // Samples on main, like updateWaveform:'s; only the pixel work leaves.
    VibeSignpostBegin(waveform_samples);
    NSData *samples = [renderer envelopeSamplesForWaveform:self.waveform.waveform];
    VibeSignpostEnd(waveform_samples);
    // A two-hue theme bakes the unplayed side too, doubling the cell's bytes
    // past WaveformZoomMath's budget: a deliberate trade.
    BOOL separateUnplayed = !renderer.theme.unplayedSharesPlayedHue;
    NSUInteger epoch = _bakeEpoch;
    _bakeInFlight = YES;
    _bakeWanted = NO;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VibeSignpostBegin(waveform_bake);
        CGImageRef image = [renderer newEnvelopeImageForSize:size scale:scale samples:samples];
        CGImageRef unplayedImage = separateUnplayed
                ? [renderer newUnplayedEnvelopeImageForSize:size scale:scale samples:samples] : NULL;
        VibeSignpostEnd(waveform_bake);
        dispatch_async(dispatch_get_main_queue(), ^{
            WaveformScrubberView *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_bakeInFlight = NO;
                [strongSelf installEnvelopeImage:image unplayedImage:unplayedImage size:size epoch:epoch];
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

- (void)installEnvelopeImage:(CGImageRef)image unplayedImage:(nullable CGImageRef)unplayedImage
                        size:(CGSize)size epoch:(NSUInteger)epoch {
    CGSize currentSize = [self virtualBounds].size;
    BOOL stretchForPinch = _isPinching && size.height == currentSize.height;
    if (!image || epoch != _bakeEpoch || !self.waveform ||
        (!CGSizeEqualToSize(size, currentSize) && !stretchForPinch)) {
        return;
    }
    VibeSignpostBegin(waveform_install);
    // One hue: the played bitmap dimmed. Two hues: the unplayed side's own
    // bake, already at its resting alphas.
    CGFloat unplayedOpacity = unplayedImage ? 1
            : [(DetailedAudioWaveformRenderer *)_renderer unplayedOverPlayedOpacity];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // TRAP: a bake may still be standing — a non-eased delivery and the
    // pinch's stretch path both leave one up — and without this removal the
    // old layer stays in the scroll's tree for the life of the view.
    [_bakedHost removeFromSuperlayer];
    // No geometryFlipped here: the bake draws in CG's y-up space, whose top
    // row lands at the layer's top, matching what the flipped live tree shows.
    _bakedHost = [CALayer layer];
    _bakedHost.anchorPoint = CGPointZero;
    _bakedHost.position = CGPointZero;      // content origin; the scroll moves it
    CGSize installedSize = stretchForPinch ? currentSize : size;
    _bakedHost.bounds = (CGRect){CGPointZero, installedSize};
    _bakedUnplayed = [CALayer layer];
    _bakedUnplayed.anchorPoint = CGPointZero;
    _bakedUnplayed.frame = (CGRect){CGPointZero, installedSize};
    _bakedUnplayed.contents = (__bridge id)(unplayedImage ?: image);
    _bakedUnplayed.opacity = (float)unplayedOpacity;
    [_bakedHost addSublayer:_bakedUnplayed];
    _bakedPlayed = [CALayer layer];
    _bakedPlayed.anchorPoint = CGPointZero;
    _bakedPlayed.position = CGPointZero;
    _bakedPlayed.contents = (__bridge id)image;
    [_bakedHost addSublayer:_bakedPlayed];
    [_scroll.layer insertSublayer:_bakedHost above:_rendererHost];
    _rendererHost.hidden = YES;
    [CATransaction commit];
    [self applyScrollAndProgress];
    VibeSignpostEnd(waveform_install);
}

- (void)showLoadingIndicator {
    if (_loadingIndicator) {
        return;
    }
    [self resetWaveformContentState];
    if (_renderer) {
        // Settled: an eased collapse costs more full-view rebuilds than the
        // whole streaming load that follows.
        [self drawWaveformSettled];
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
    if (![_loadingIndicator endSweepKeepingFill]) {
        [self hideLoadingIndicator];
    }
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

- (void)setLoadingProgress:(float)fraction {
    _loadingTrackBounds = [self loadingTrackBounds];
    [_loadingIndicator setProgress:fraction inBounds:_loadingTrackBounds];
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
    // Without a bake a pinch frame is a full-width mask rebuild; bake now.
    if (!_bakedHost && _renderer) {
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:0];
    }
}

- (void)endZoomGesture {
    // Stop a coast the dying pan started, while the flag still routes its
    // scroll to the park: let run, scrollViewDidScroll: would read a position
    // out of it that no seek follows.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _isPinching = NO;
    if (_renderer) {
        // The live tree is at the gesture's starting geometry and the bitmap
        // stretched and soft: resync both.
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:0];
    }
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
}

// Layout and the zoom both call this: a zoom moves the virtual width with the
// bounds unchanged.
- (void)applyVirtualGeometry {
    VibeSignpostBegin(waveform_geometry);
    CGRect virtualBounds = [self virtualBounds];
    CGSize previous = _rendererHost.bounds.size;
    BOOL sizeChanged = !CGSizeEqualToSize(previous, virtualBounds.size);
    // A pinch frame STRETCHES the bake (soft until the re-bake on release)
    // rather than rebuilding a multi-screen mask; every other resize tears it
    // down.
    BOOL stretchBake = _isPinching && _bakedHost
            && previous.height == virtualBounds.size.height;
    // Early pinch frames can beat beginZoomGesture's bake; keep its epoch so it
    // installs stretched.
    BOOL awaitingPinchBake = _isPinching && !_bakedHost;
    if (sizeChanged && !stretchBake && !awaitingPinchBake) {
        [self teardownBakedWaveform];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.frame = self.bounds;
    CGFloat centerX = self.bounds.size.width / 2;
    _scroll.contentInset = UIEdgeInsetsMake(0, centerX, 0, centerX);
    _scroll.contentSize = CGSizeMake(virtualBounds.size.width, self.bounds.size.height);
    _rendererHost.bounds = virtualBounds;
    if (stretchBake) {
        // Resize gravity scales it; the played crop follows virtualWidth.
        _bakedHost.bounds = virtualBounds;
        _bakedUnplayed.frame = virtualBounds;
    }
    [CATransaction commit];
    [self applyScrollAndProgress];
    // The bucket is per pixel of the virtual width, which just moved; without
    // this every playback write during a pinch passes setProgress:'s gate.
    _progressTracker = [self progressBucket];
    // A stretched bake hides the live tree, which endZoomGesture resyncs.
    if (sizeChanged && _renderer && !stretchBake) {
        // Even with no waveform, so a mid-collapse morph rebuilds at the new
        // size. Settled and baked next turn: a resize has no new shape to ease
        // into. traitsDidChange: schedules its own later bake, whose request
        // is the one that bakes.
        [self drawWaveformSettled];
        if (!_isPinching) {
            [self scheduleEnvelopeBakeAfter:0];
        }
    }
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
    if (scaleChanged || styleChanged) {
        [self teardownBakedWaveform];
    }
    if (scaleChanged) {
        VibeApplyContentsScale(self.layer, [self displayScale]);
        [_renderer backingScaleDidChange];
        // The scale moves the zoom floor with the bounds unchanged, and no
        // layout pass follows.
        [self applyVirtualGeometry];
    }
    if (styleChanged) {
        // Re-resolved, not just recolored: the theme is per appearance.
        [self applyResolvedTheme];
        [_loadingIndicator updateColorsForDark:self.isDark];
    }
    if (scaleChanged || styleChanged) {
        [self applyScrollAndProgress];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
}

@end
