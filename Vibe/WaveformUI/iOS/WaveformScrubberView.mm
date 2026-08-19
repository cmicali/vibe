//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "DetailedAudioWaveformRenderer.h"
#import "WaveformRendererRegistry.h"
#import "WaveformLoadingIndicator.h"
// The zoom range and the bake's ceilings, which are one set of numbers.
#import "WaveformZoomMath.h"
#import "UIView+DarkMode.h"
#import "AppSettings.h"

// The XCUITest driver's pinch needs an ELEMENT to center on — XCUITest has no
// coordinate-based multi-touch, only pinchWithScale:velocity: on an element.
// An accessibilityIdentifier alone puts the view in the element tree;
// isAccessibilityElement stays off, so VoiceOver behavior is unchanged. Spelled
// the same in Tests/iOSDriver/VibeiOSDriverTests.m.
static NSString *const kWaveformScrubberIdentifier = @"waveform-scrubber";

// One haptic tick per this many points of scrub travel, and how hard each one
// hits. Tight spacing so a slow, deliberate scrub ratchets continuously under
// the finger instead of landing on occasional detents; the per-frame bucket
// check caps delivery at display rate, so a fast throw thins out by itself
// rather than turning into a buzz.
//
// Rigid impact, not selection feedback: selection is deliberately soft and
// rounded, and a scrub wants a short, sharp edge. Intensity stays well under
// full because this fires many times a second — a full-strength tap at this
// rate is fatiguing within a gesture or two.
static const CGFloat kScrubTickSpacing = 1.0;
static const CGFloat kScrubTickIntensity = 0.55;

// TRAP: the spacing above is a DISTANCE, and distance alone is not a rate. A
// fast scrub crosses it every frame, which asks the Taptic Engine for 60-120
// taps a second; it cannot produce distinct taps anywhere near that, so it
// drops them, and sustained over-requesting takes it out entirely — the scrub
// goes dead and stays intermittent for seconds afterwards, well past the
// gesture. This ceiling is what keeps a fast scrub a ratchet instead of a
// flood. Slow scrubs never reach it and stay purely distance-driven.
static const CFTimeInterval kScrubTickMinInterval = 1.0 / 28.0;

// How long after the last waveform delivery the settled bitmap is baked: past
// the morph engine's ease (about 95% settled at 0.2s), so the swap from live
// tree to bitmap lands on identical pixels.
static const NSTimeInterval kEnvelopeBakeDelay = 0.6;

// The floor on how often a settled delivery may re-bake. A streaming decode
// delivers about ten times a second and each bake is 20-35ms of background pixel
// work plus a multi-megabyte bitmap (measured on device), which three pager
// cells could be paying at once — so the picture steps forward at this rate
// instead. Trailing: the last delivery inside a window is the one that bakes,
// so the newest shape always wins and no delivery is merely dropped.
static const NSTimeInterval kLoadBakeMinInterval = 0.25;

@interface WaveformScrubberView () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // The scroll that carries the content. Its contentSize is the virtual
    // (zoomed) width and its insets are half a view on each side, so the
    // content rests under the view's center at both ends of the track and
    // UIKit supplies the band, the spring and the deceleration. Everything
    // that scrolls is a sublayer of ITS layer; the loading indicator stays in
    // self.layer, which does not move.
    UIScrollView            *_scroll;
    // The renderers' parent layer. geometryFlipped gives its sublayers the
    // bottom-left-origin space the shared renderer math was written for (the
    // mac view is a non-flipped layer-hosting NSView), so SonicCirrus's
    // top/mirror layout and the Detailed gradients render identically with
    // zero shared-code change. Its bounds are the virtual (zoomed) size, not
    // the view's, and it sits at content origin.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
    // The style _renderer was built from, so a settings change is a comparison
    // rather than a rebuild on every page that comes on screen.
    NSString                *_styleIdentifier;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    // The loading control, shared with the mac view: its own layers, its
    // determinate fill and the sweep's traps all live there. Nil when no load
    // is showing.
    WaveformLoadingIndicator *_loadingIndicator;
    // The scrub-tick haptic and the last virtual-x bucket that fired it.
    UIImpactFeedbackGenerator *_scrubHaptics;
    NSInteger               _lastTickBucket;
    CFTimeInterval          _lastTickTime;
    // YES between the scroll's first user-driven frame and its seek commit,
    // so the commit happens once per gesture rather than per delegate call.
    BOOL                    _seekPending;
    // The settled fast path: the envelope baked into one bitmap, shown by two
    // image layers — unplayed across the full width, played stacked on top of
    // it (the same compositing order as the live tree's played clip) and
    // cropped by contentsRect. Non-nil _bakedHost means the fast path is in
    // and _rendererHost is hidden. The generation invalidates in-flight bakes.
    CALayer                 *_bakedHost;
    CALayer                 *_bakedUnplayed;
    CALayer                 *_bakedPlayed;
    NSUInteger              _bakeGeneration;
    // When the last bake actually started, for the load-time rate limit. Zero
    // means "never", which reads as long ago and so bakes at once.
    CFTimeInterval          _lastBakeAt;
    // The zoom: the requested fraction (see the property), the pinch that
    // drives it, and the fraction the current gesture started from. _isPinching
    // is what tells applyVirtualGeometry to stretch the baked bitmap instead of
    // tearing it down.
    CGFloat                 _visibleFraction;
    UIPinchGestureRecognizer *_pinch;
    BOOL                    _isPinching;
    CGFloat                 _pinchStartFraction;
    // The scrub the PINCH drives once the scroll's pan has died under it (see
    // handlePinch:): the last centroid x it was measured from, and the touch
    // count that centroid belongs to — a change in the count moves the point
    // without the hand moving, so it re-anchors rather than scrubbing.
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
    // The content extends several screen widths past both edges.
    self.clipsToBounds = YES;
    self.accessibilityIdentifier = kWaveformScrubberIdentifier;
    _visibleFraction = kVibeWaveformDefaultZoomFraction;

    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.delegate = self;
    _scroll.bounces = YES;
    _scroll.alwaysBounceHorizontal = YES;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    // A throw has to settle fast: this is a scrubber, not a document.
    _scroll.decelerationRate = UIScrollViewDecelerationRateFast;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // TRAP: a UIScrollView owns its pan's delegate and raises on assignment,
    // so the "no waveform, no scrub" gate rides scrollEnabled instead — see
    // setWaveform:.
    //
    // TRAP: this pan cannot carry a gesture across a change in touch count. It
    // ENDS the moment a finger is added or lifted — measured on device — and an
    // ended recognizer is never given touches that were already down, so it
    // cannot come back for the finger still on the glass. Capping it at one
    // touch only makes that happen sooner. Everything from the pinch's first
    // frame to the hand leaving is therefore carried by the pinch instead
    // (trackZoomGestureScrub:); this pan owns the ordinary one-finger scrub and
    // nothing else.
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
    // The whole content motion, finger and coast and bounce alike: the span
    // over which the progress writers must keep off the scroll. A live pinch
    // counts even after the scroll's pan has died under it, because the pinch
    // is then driving the position itself — without this the 3 Hz tick and the
    // display link would both write playback's position over the finger's.
    return _isPinching || _scroll.isDragging || _scroll.isDecelerating || _scroll.isTracking;
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

// How far the offset is outside its valid range: positive past the start,
// negative past the end. Diagnostic only — nothing draws from it.
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

// With nothing to scrub the pan must not recognize at all, or it swallows the
// page swipe: the pager's requireGestureRecognizerToFail: is satisfied forever
// by a recognizer that always begins, and an empty strip becomes a dead zone.
// A disabled scroll's pan counts as failed, which is exactly what that wants.
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

// The deepest zoom this geometry's settled bitmap can hold. It moves with the
// view size and the display scale, which is the whole reason the request is
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
    // A request the floor swallows moves nothing on screen, so it costs no
    // layout — which is also what makes the pinch's hard stop free.
    if ([self effectiveVisibleFraction] != previous) {
        [self applyVirtualGeometry];
    }
}

#pragma mark - Renderer lifecycle

// The zoomed content width the renderer draws into; 0 before layout. Reads the
// EFFECTIVE fraction, so everything derived from it — the scroll's content
// size, the offset/progress mapping, the buckets, the bake — is clamped to
// what can actually be drawn without any of them knowing about the clamp.
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
    // The persisted style, then the app default; the registry owns the chain,
    // as it does for the mac view.
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    Class rendererClass = [WaveformRendererRegistry rendererClassForIdentifier:style];
    if (!rendererClass) {
        return;
    }
    _styleIdentifier = style;
    _rendererHost.contentsScale = [self displayScale];
    // The renderer reads parentLayer.bounds, so the host must be at virtual
    // size before it exists.
    _rendererHost.bounds = [self virtualBounds];
    _renderer = [[rendererClass alloc] initWithLayer:_rendererHost
                                              bounds:[self virtualBounds]
                                              isDark:self.isDark];
}

- (void)syncWaveformStyle {
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:[[AppSettings sharedInstance] waveformStyle]];
    if (!_renderer || [style isEqualToString:_styleIdentifier]) {
        // Nothing on screen to rebuild: the next install reads the setting.
        return;
    }
    // The renderer removes its own layers as it goes, so dropping it is the
    // teardown. The baked bitmap is the outgoing style's picture and has to
    // come down with it; a fresh bake is scheduled for the next turn, since
    // there is no morph to wait out — the bars land already settled.
    [self teardownBakedWaveform];
    _renderer = nil;
    [self installRendererIfNeeded];
    [self drawWaveformSettled];
    [self scheduleEnvelopeBakeAfter:0];
}

- (void)drawWaveform {
    [_renderer updateWaveform:[self virtualBounds] progress:_progress waveform:self.waveform.waveform];
    [self applyScrollAndProgress];
}

// The same draw with the morph landed rather than eased. Every presentation
// reset on this platform is a recycled pager cell being emptied off-screen, so
// easing 4,096 bars to the midline with nobody watching is pure per-frame cost
// — and it is charged to the swipe that recycled the cell.
- (void)drawWaveformSettled {
    [self drawWaveform];
    [_renderer settleMorphImmediately];
}

// The offset that puts the track's `progress` point under the view's center,
// and its inverse. The insets are half a view wide on each side, so progress 0
// sits at -centerX and progress 1 at virtualWidth - centerX.
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

// The same park, written whether or not the scroll believes it is being
// touched. TRAP: the guard above declines while isScrubbing, and a cancelled
// scroll does not clear isDragging/isTracking until the touch is delivered —
// so a reset, or a pinch whose own fingers are still down, has to write it
// unconditionally or the content stays where the last gesture left it.
- (void)parkContentOffsetAtProgress {
    CGFloat x = [self contentOffsetForProgress:MAX(0.0, MIN(1.0, _progress))];
    // Also what bounds the re-entry: a pinch frame parks from inside
    // scrollViewDidScroll:, whose write comes straight back here.
    if (fabs(_scroll.contentOffset.x - x) < 0.01) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.contentOffset = CGPointMake(x, 0);
    [CATransaction commit];
}

// The played/unplayed boundary — the only playhead marker, no line. It lives
// in CONTENT space, spanning content x 0..progress*virtualWidth, so the scroll
// carries it to the view's center for free and nothing here reads the offset.
- (void)applyPlayedClip {
    CGFloat virtualWidth = [self virtualWidth];
    if (!_renderer || virtualWidth <= 0) {
        return;
    }
    // The timer writers push raw position/duration, which can land a hair
    // past 1.0 at track end, and a bounce puts the derived progress out of
    // unit at both ends; an out-of-unit contentsRect smears the baked image's
    // edge pixels across the excess.
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
        // The headline number for any change to the bake's lifetime: the two
        // branches cost the same on THIS thread and nothing like the same in
        // the render server, so which one a frame took is the measurement.
        VibeTallyCount(waveform_progress_live);
    }
    [CATransaction commit];
}

#pragma mark - Progress

- (NSUInteger)progressBucket {
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)([self virtualWidth] * [self displayScale]));
    // TRAP: clamp before the cast, not after. setProgress: stores what the
    // timer writers hand it, which can land a hair outside the unit range at
    // track end, and converting a negative or overlarge double to NSUInteger
    // is undefined rather than merely wrong.
    return static_cast<NSUInteger>(MAX(0.0, MIN(1.0, _progress)) * steps);
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    // Repaint whenever the boundary crosses a device pixel of the virtual
    // (scrolled) axis; same gate as the mac view, fed from the trait
    // collection instead of the window.
    NSUInteger p = [self progressBucket];
    if (_progressTracker != p) {
        _progressTracker = p;
        [self applyScrollAndProgress];
    }
}

- (CGFloat)progress {
    return _progress;
}

#pragma mark - Presentation states

- (void)resetWaveformContentState {
    [self teardownBakedWaveform];
    // A new track's first chunk must not be held back by the previous track's
    // bake, which is what the rate limit would otherwise do.
    _lastBakeAt = 0;
    // Stop a coast where it stands, then drop the waveform — which disables
    // the scroll and so cancels any in-flight drag. A drag or coast straddling
    // a track change must not keep scrubbing the new track from the old one's
    // progress; the finger has to re-begin against the new content.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _seekPending = NO;
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
    self.waveform = nil;
    // Force the repaint even when the bucket is already 0, so the reset
    // always re-parks the translation.
    _progressTracker = NSUIntegerMax;
    self.progress = 0;
    // TRAP: the cancel above does not clear isDragging until the touch is
    // delivered, so the progress write can skip its park and leave a recycled
    // cell scrolled to the previous track's position. Park unconditionally.
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
    // Data arrival is what genuinely ends the shimmer — the audio open landing
    // does not (its decode may still be streaming over the network), so the
    // owner leaves it up until this delivery. The download fill is NOT ended
    // here: a disk-cached waveform arrives without materializing the audio
    // file, so the provider can still
    // be downloading it — the fill then rides over the waveform as the only
    // sign of that, and it comes down with its monitor (the open landing or
    // the error path clears it via setLoadingProgress:-1).
    [self hideLoadingShimmer];
    // A fresh view may receive data before anyone called
    // prepareForWaveformLoad (per-page cells hydrate directly); the renderer
    // must exist before the draw.
    [self installRendererIfNeeded];
    VibeSignpostBegin(waveform_delivery);
    // An ease needs something to ease FROM, and the only state worth easing from
    // is nothing: bars at rest on the midline rising into the full shape, which
    // is what a disk-cached waveform arriving on a freshly reset page does.
    //
    // A delivery that replaces a shape already on screen has no such story. The
    // one that completes a STREAMING decode looks like it should — it is the
    // last delivery, so the caller asks for an ease — but what it actually
    // animates is the trailing chunks the partial deliveries left at zero,
    // springing to full amplitude. Measured: 16-18 full-view path rebuilds with
    // the bake down for kEnvelopeBakeDelay, which was 70% of the whole load's
    // rebuild cost and more than the deliveries themselves.
    BOOL ease = animated && self.waveform == nil;
    self.waveform = waveform;
    if (ease) {
        // The morph is the point here, and it is a LIVE TREE surface: the bake
        // has to come down so the ease can be seen, and it re-lands once the
        // deliveries stop.
        [self teardownBakedWaveform];
        [self drawWaveform];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
    else {
        // TRAP: do NOT tear the bake down here. There is no ease to reveal — the
        // bars land on the target in one rebuild — so the outgoing bitmap is a
        // fractionally stale picture of the same waveform, and leaving it up is
        // what keeps a streaming load on the fast path from end to end. Tearing
        // it down instead unhid the live tree on every one of ~10 deliveries a
        // second, and since each delivery also pushed the re-bake out by
        // kEnvelopeBakeDelay, the bitmap never came back for the whole load.
        //
        // The live tree is still brought up to date underneath (hidden), so
        // whatever unhides it next — a track change, a resize, an eased
        // delivery — finds it drawing the current shape.
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:[self throttledBakeDelay]];
    }
    VibeSignpostEnd(waveform_delivery);
}

// 0 when nothing has baked recently, otherwise the remainder of the window — so
// a burst of deliveries collapses to one bake at the window's end rather than
// one apiece.
- (NSTimeInterval)throttledBakeDelay {
    CFTimeInterval since = CACurrentMediaTime() - _lastBakeAt;
    if (since >= kLoadBakeMinInterval) {
        return 0;
    }
    return kLoadBakeMinInterval - since;
}

#pragma mark - Settled bitmap fast path

// Scrolling and scrubbing pay the live tree's price every frame: the
// renderer's thousands-of-rects shape mask covers the whole multi-screen
// virtual layer, and a masked group re-composites offscreen, in full, on any
// change of translation or played-clip width. Once the load morph settles the
// picture is static, so it is baked into a single bitmap and the per-frame
// work collapses to translating textures. The live tree remains the morph
// surface: every reset, delivery, and geometry or trait change tears the fast
// path down first, and the bake re-lands after the morph has settled.

- (void)teardownBakedWaveform {
    _bakeGeneration++;
    if (!_bakedHost) {
        return;
    }
    // Same transaction discipline as the install: these are manual sublayers,
    // so unhiding the live tree without disabling actions picks up the
    // implicit fade and blanks the waveform for a frame on every delivery,
    // rotation, and appearance flip.
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
    _bakeGeneration++;
    if (!self.waveform || ![_renderer isKindOfClass:DetailedAudioWaveformRenderer.class]) {
        return;
    }
    NSUInteger generation = _bakeGeneration;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf bakeEnvelopeForGeneration:generation];
    });
}

- (void)bakeEnvelopeForGeneration:(NSUInteger)generation {
    if (generation != _bakeGeneration || !self.waveform) {
        return;
    }
    CGSize size = [self virtualBounds].size;
    if (size.width <= 0 || size.height <= 0) {
        return;
    }
    _lastBakeAt = CACurrentMediaTime();
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)_renderer;
    CGFloat scale = [self displayScale];
    // A CALayer whose contents exceed the GPU texture ceiling renders BLANK,
    // and the virtual width crosses it on wide iPad windows (view width /
    // visibleFraction × scale). Bake at a reduced scale instead — the layers'
    // default resize gravity stretches it back, softening the bars slightly,
    // which beats an invisible waveform. A width that cannot fit even at 1x
    // would need a ~3250pt view; bail to the live tree if it ever happens.
    //
    // The zoom floor is derived from this same ceiling, so a PINCH can never
    // get here; what does is a layout wide enough that even the resting zoom
    // overflows.
    if (size.width * scale > kVibeMaxBakeImagePixels) {
        scale = kVibeMaxBakeImagePixels / size.width;
        if (scale < 1) {
            return;
        }
    }
    // Samples come out on the main thread — the same access updateWaveform:
    // performs — so only the pixel work leaves it.
    VibeSignpostBegin(waveform_samples);
    NSData *samples = [renderer envelopeSamplesForWaveform:self.waveform.waveform];
    VibeSignpostEnd(waveform_samples);
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VibeSignpostBegin(waveform_bake);
        CGImageRef image = [renderer newEnvelopeImageForSize:size scale:scale samples:samples];
        VibeSignpostEnd(waveform_bake);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf installEnvelopeImage:image size:size generation:generation];
            CGImageRelease(image);
            // Deliberately captured: if the view died during the bake, the
            // background block above must not do the renderer's final
            // release — its dealloc tears down layers, main-thread work.
            (void)renderer;
        });
    });
}

- (void)installEnvelopeImage:(CGImageRef)image size:(CGSize)size generation:(NSUInteger)generation {
    CGSize currentSize = [self virtualBounds].size;
    BOOL stretchForPinch = _isPinching && size.height == currentSize.height;
    if (!image || generation != _bakeGeneration ||
        (!CGSizeEqualToSize(size, currentSize) && !stretchForPinch)) {
        return;
    }
    VibeSignpostBegin(waveform_install);
    CGFloat unplayedOpacity = [(DetailedAudioWaveformRenderer *)_renderer unplayedOverPlayedOpacity];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // TRAP: this cannot assume there is no bake standing. Every bake used to be
    // preceded by a teardown; the pinch's stretch path (applyVirtualGeometry)
    // deliberately leaves one up, and without this removal the old layer stays
    // in the scroll's layer tree for the life of the view.
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
    _bakedUnplayed.contents = (__bridge id)image;
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
        // SETTLED, as prepareForWaveformLoad's collapse is, and measured as the
        // single biggest cost of a track change: eased, this walks 4,096 bars
        // down to the midline at 60 Hz for ~0.2s — about twelve full-view path
        // rebuilds with the bake already torn down — which is more than the
        // whole streaming load that follows it costs.
        [self drawWaveformSettled];
    }
    _loadingIndicator = [[WaveformLoadingIndicator alloc]
            initInLayer:self.layer
                 isDark:self.isDark
          contentsScale:[self displayScale]];
    [self layoutLoadingLayer];
}

- (void)layoutLoadingLayer {
    [_loadingIndicator layoutInBounds:self.bounds];
}

// Data arrival ends the shimmer but deliberately NOT the download fill: a
// disk-cached waveform can arrive while the provider is still materializing
// the audio, and the fill riding over the waveform is the only sign of that.
// The fill comes down with its monitor, via setLoadingProgress:-1.
- (void)hideLoadingShimmer {
    if (![_loadingIndicator endSweepKeepingFill]) {
        [self hideLoadingIndicator];
    }
}

- (void)hideLoadingIndicator {
    [_loadingIndicator removeFromHost];
    _loadingIndicator = nil;
}

// Determinate download progress, fed by whatever source knows a fraction —
// today the allocated-size monitor. The control owns the easing and the
// indeterminate revert; see WaveformLoadingIndicator.
- (void)setLoadingProgress:(float)fraction {
    [_loadingIndicator setProgress:fraction inBounds:self.bounds];
}

#pragma mark - Touch scrubbing

// Direct manipulation, UIKit's: the drag moves the content 1:1 under the fixed
// center playhead, a flick coasts, both ends give and spring back, and the
// seek commits as soon as the content reaches the point it will settle on. A
// cancelled drag just stops; the next progress push restores the true
// position.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // While a pinch is up the zoom owns the picture: the pan is still running
    // (it has to be, so scrubbing can resume when a finger stays down) and it
    // still moves the offset, but each pinch frame parks that offset back at
    // the playhead. Reading progress out of it here would let the first finger
    // drag the position around underneath the zoom.
    if (_isPinching) {
        // The pan is still running underneath — it has to be, or scrubbing
        // could not resume when a finger stays down — so its translation keeps
        // arriving here. Pull the content back to the playhead rather than
        // reading a position out of it: the zoom owns the picture, and a pinch
        // that drifts across the glass would otherwise slide the waveform out
        // from under the center between one scale change and the next.
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

// One haptic tick per bucket of scrub travel, rate-limited. Shared with the
// pinch's own scrub so a gesture that changes hands does not lose its ratchet.
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
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
    _seekPending = YES;
    _scrubHaptics = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleRigid];
    [_scrubHaptics prepare];
    _lastTickBucket = [self tickBucket];
    _lastTickTime = 0;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self endScrub];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self endScrub];
}

// The content has stopped, so the seek commits and the progress writers take
// back over. TRAP: this is the ONLY place a scrub seeks. Committing earlier —
// on reaching an end mid-gesture — reads as correct and is not: a seek to 1.0
// lands the player on the track's end, which finishes it and auto-advances,
// so pushing against the end skipped to the next track with the finger still
// down. UIScrollView also reports isDecelerating DURING a drag, so there is no
// "still moving" test that separates a coast from a finger.
- (void)endScrub {
    if (_isPinching) {
        // TRAP: the scroll's pan dies mid-gesture — it ends the instant the
        // touch count changes, which is every pinch that starts from or ends
        // in a one-finger drag. Nothing is finished here: seeking now would
        // commit a position the finger is still moving away from, and
        // releasing the pager would re-open the swipe under it. The pinch owns
        // the seek, the haptics and the hold until the hand leaves.
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

// A tap nudges to the tapped point within the visible window. The scroll's own
// bounds origin IS the content offset, so a location in its space is already a
// content x.
- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (!self.waveform || tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return;
    }
    CGFloat p = [tap locationInView:_scroll].x / virtualWidth;
    // A tap mid-coast claims the transport: left running, the deceleration
    // would settle later and commit a second seek over this one. Stopping an
    // animated offset does not reliably call scrollViewDidEndDecelerating:, so
    // explicitly release the pager hold the coast took.
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

// Zoom is anchored at the playhead for free. The design guarantee
// `contentOffset.x == progress·virtualWidth - centerX` puts the played
// boundary at the view's center whatever the virtual width is, so changing the
// width and re-parking the offset opens the picture about it with no anchor
// math — and around the point being listened to, which is the DJ behavior.
//
// The fraction is written LIVE rather than accumulated into a transform and
// committed on release. One number means the scroll's content size, insets and
// end stops stay honest on every frame and every reader of virtualWidth stays
// correct with no gesture-aware special case; what is deferred is only the
// bake. See applyVirtualGeometry for the other half.
// TRAP: without this a pinch cannot START during a scrub. By the time the
// second finger lands the scroll's pan has already recognized, and UIKit's
// default is that one gesture belongs to one recognizer — so the pinch is
// refused, the second finger does nothing, and the zoom is simply unreachable
// from a drag, which is how a finger already on the waveform arrives at it.
//
// The pan is left running rather than cancelled, but do not count on it to
// last: it ends on its own the moment the touch count changes. What carries
// the gesture after that is trackZoomGestureScrub:.
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
                    // Pinch open (scale > 1) is zoom IN, so LESS of the track
                    // is visible. Clamped against the EFFECTIVE floor, not the
                    // absolute one, so the gesture stops exactly where the
                    // picture does — a hard stop — and the committed request
                    // can never sit below what this geometry can draw.
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

// The scrub, once the pinch owns it.
//
// TRAP: UIScrollView's pan ENDS the moment the touch count changes, so lifting
// the second finger of a pinch kills it with a finger still on the glass — and
// an ended recognizer cannot begin again for a touch that is already down.
// UIPinchGestureRecognizer, meanwhile, stays in Changed with one finger left.
// So from the pinch's first frame the pinch is the only thing that can carry
// the gesture to its end, and this is what moves the track under the remaining
// finger. Measured on device: 148 frames of one-touch pinch with the pan dead.
//
// Only ONE touch scrubs. With two the centroid is the zoom's own anchor and
// moving it is how a pinch drifts, not how a scrub is asked for — so the
// position holds still while zooming, which is what "switch to pinch" means.
- (void)trackZoomGestureScrub:(UIPinchGestureRecognizer *)pinch {
    CGFloat x = [pinch locationInView:self].x;
    NSUInteger touches = pinch.numberOfTouches;
    CGFloat virtualWidth = [self virtualWidth];
    // A change in the touch count moves the centroid without the hand moving.
    // Re-anchor on it or the 2->1 jump lands as one enormous scrub.
    if (touches == 1 && touches == _zoomScrubTouches && virtualWidth > 0) {
        // Dragging left carries the track forward under the fixed playhead.
        CGFloat delta = (x - _zoomScrubLastX) / virtualWidth;
        CGFloat next = MAX(0.0, MIN(1.0, _progress - delta));
        if (next != _progress) {
            _progress = next;
            _progressTracker = [self progressBucket];
            _seekPending = YES;     // committed when the hand finally leaves
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
    // Stop a coast where it stands. A pending seek is deliberately NOT dropped:
    // the picture is frozen where the scrub left it, so committing there on
    // lift is the position the user is looking at.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    // Kept, not dropped: the pinch may hand the scrub back to one finger, and
    // that half of the gesture ratchets like any other.
    if (!_scrubHaptics) {
        _scrubHaptics = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleRigid];
        [_scrubHaptics prepare];
        _lastTickBucket = [self tickBucket];
    }
    // The same hold a scrub takes, for the same reason — see the protocol
    // comment. A zoom is direct manipulation of the waveform too.
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
    // The gesture wants the fast path: with a bake up a frame is a texture
    // scale, without one it is a full-width mask rebuild. Settling and baking
    // now collapses that window to the frame or two before it lands.
    if (!_bakedHost && _renderer) {
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:0];
    }
}

- (void)endZoomGesture {
    _isPinching = NO;
    if (_renderer) {
        // The live tree was left at the geometry the gesture started from —
        // applyVirtualGeometry stretched the bitmap instead of redrawing it —
        // so bring it back in sync before anything can unhide it, and re-bake
        // so the stretched, soft bitmap is replaced by one at the true size.
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:0];
    }
    [self parkContentOffsetAtProgress];
    // The hand has left: this is the end of the whole gesture, however it
    // started. endScrub declined all of this while the pinch was live, so the
    // seek, the haptics and the pager hold are all settled here.
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

// The scroll's content geometry for the current bounds and zoom, and the bake's
// answer to a change in it. Layout calls this; so does the zoom, which moves
// the virtual width without the view's bounds moving at all.
- (void)applyVirtualGeometry {
    VibeSignpostBegin(waveform_geometry);
    CGRect virtualBounds = [self virtualBounds];
    CGSize previous = _rendererHost.bounds.size;
    BOOL sizeChanged = !CGSizeEqualToSize(previous, virtualBounds.size);
    // A pinch frame STRETCHES the baked bitmap rather than tearing it down: the
    // picture goes slightly soft until the re-bake lands on release, which is
    // invisible against a moving one, and it is the whole reason a zoom frame
    // costs a texture scale instead of a 4,096-rect mask rebuild over a
    // multi-screen layer. Only the width moves under a pinch; every other
    // resize — rotation, a trait change — keeps the teardown, so nothing
    // outside the gesture changes behavior.
    BOOL stretchBake = _isPinching && _bakedHost
            && previous.height == virtualBounds.size.height;
    // The first pinch frames can arrive before the bake requested by
    // beginZoomGesture finishes. Keep that request current; its image can be
    // installed and stretched to the then-current width, after which the
    // ordinary stretch path carries the rest of the gesture.
    BOOL awaitingPinchBake = _isPinching && !_bakedHost;
    if (sizeChanged && !stretchBake && !awaitingPinchBake) {
        // The bitmap is baked for the old size; the live tree carries the
        // resize and the bake re-lands at the new one.
        [self teardownBakedWaveform];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scroll.frame = self.bounds;
    // Half a view of inset on each side is what parks the content under the
    // center at both ends of the track instead of against the view's edges.
    CGFloat centerX = self.bounds.size.width / 2;
    _scroll.contentInset = UIEdgeInsetsMake(0, centerX, 0, centerX);
    _scroll.contentSize = CGSizeMake(virtualBounds.size.width, self.bounds.size.height);
    _rendererHost.bounds = virtualBounds;
    if (stretchBake) {
        // The layers' default resize gravity does the scaling. applyPlayedClip
        // recomputes the played crop from virtualWidth, so it follows for free.
        _bakedHost.bounds = virtualBounds;
        _bakedUnplayed.frame = virtualBounds;
    }
    [CATransaction commit];
    [self applyScrollAndProgress];
    // Nothing to redraw while a bake is being stretched — the live tree is
    // hidden, and endZoomGesture re-syncs it before it can be unhidden. Without
    // a bake to stretch the pinch has to fall back to redrawing, which is the
    // expensive path it exists to avoid; beginZoomGesture keeps that window to
    // the frame or two before its bake lands.
    if (sizeChanged && _renderer && !stretchBake) {
        // Sync geometry even with no waveform, as the mac view does, so a
        // mid-collapse morph rebuilds at the new size.
        //
        // SETTLED, and the bake asked for on the next turn rather than after
        // kEnvelopeBakeDelay: a resize is not a delivery, so there is no new
        // shape to grow into — the bars are already on their target and the
        // delay was spent waiting out a morph that will not run. What it
        // actually bought was 0.6s of every frame carried by the live tree,
        // starting from the frame the teardown above landed on. Where a morph
        // IS in flight, snapping it is invisible against a view whose own
        // bounds just changed, and it is the trade showWaveform:animated:NO
        // already makes for the same reason.
        //
        // A trait change is unaffected: traitsDidChange: schedules its own bake
        // afterwards, and the later call's generation is the one that lands.
        [self drawWaveformSettled];
        if (!_isPinching) {
            [self scheduleEnvelopeBakeAfter:0];
        }
    }
    if (sizeChanged) {
        [self layoutLoadingLayer];
        // Separated from the interval below so a trace can tell a layout pass
        // that merely reached here from one that actually moved the width — the
        // teardown, the redraw and the re-bake all hang off this branch.
        VibeSignpostCount(waveform_resize);
    }
    VibeSignpostEnd(waveform_geometry);
}

- (void)traitsDidChange:(UITraitCollection *)previous {
    BOOL scaleChanged = previous.displayScale != self.traitCollection.displayScale;
    BOOL styleChanged = previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle;
    if (scaleChanged || styleChanged) {
        // The bitmap baked the old scale's pixel grid or the old colors.
        [self teardownBakedWaveform];
    }
    if (scaleChanged) {
        VibeApplyContentsScale(self.layer, [self displayScale]);
        [_renderer backingScaleDidChange];
        // The scale is an input to the zoom floor (WaveformZoomMath.h), so it
        // can move the virtual width with the view's own bounds unchanged —
        // and then no layout pass would follow to resize the content.
        [self applyVirtualGeometry];
    }
    if (styleChanged) {
        [_renderer updateColors:self.isDark];
        [_loadingIndicator updateColorsForDark:self.isDark];
    }
    if (scaleChanged || styleChanged) {
        [self applyScrollAndProgress];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
}

@end
