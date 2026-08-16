//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "DetailedAudioWaveformRenderer.h"
#import "WaveformRendererRegistry.h"
// The midline height and palette, shared with the mac view.
#import "WaveformMidline.h"
#import "WaveformLoadingIndicator.h"
#import "UIView+DarkMode.h"
#import "VibeWeakProxy.h"
#import "AppSettings.h"

// Fraction of the track visible across the view: the DJ zoom level, and the
// one knob the whole scrubber's scale hangs off — a preference or a pinch
// gesture would drive this and nothing else. The renderer draws the full track
// at width / fraction and the host layer is translated so the play position
// sits at the view's horizontal center. Raising it shows more time and, as a
// free consequence, shrinks the virtual layer tree.
static const CGFloat kWaveformVisibleFraction = 0.4;

// Momentum: the per-millisecond deceleration (much higher friction than
// UIScrollView's 0.998 normal rate, so a throw settles noticeably faster —
// this is a scrubber, not a scroll view), the flick floor below which a
// release settles immediately, and the speed (in view points/second of
// content motion) at which a decelerating scroll stops and commits the seek.
static const CGFloat kDecelerationPerMillisecond = 0.992;
static const CGFloat kMomentumMinimumFlick = 60.0;
static const CGFloat kMomentumSettleSpeed = 25.0;

// One haptic tick per this many points of virtual (zoomed) travel. Kept just
// a few bars apart so a scrub reads as a continuous ripple — the finger
// dragging across the waveform's lines — rather than discrete detents; the
// per-frame bucket check caps delivery at display rate on fast throws.
static const CGFloat kScrubTickSpacing = 2.0;

// How long after the last waveform delivery the settled bitmap is baked: past
// the morph engine's ease (about 95% settled at 0.2s), so the swap from live
// tree to bitmap lands on identical pixels.
static const NSTimeInterval kEnvelopeBakeDelay = 0.6;

@interface WaveformScrubberView ()
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // The renderers' parent layer. geometryFlipped gives its sublayers the
    // bottom-left-origin space the shared renderer math was written for (the
    // mac view is a non-flipped layer-hosting NSView), so SonicCirrus's
    // top/mirror layout and the Detailed gradients render identically with
    // zero shared-code change. Its bounds are the virtual (zoomed) size, not
    // the view's, and its position scrolls with playback.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    BOOL                    _isScrubbing;
    CGFloat                 _dragStartProgress;
    // The loading control, shared with the mac view: its own layers, its
    // determinate fill and the sweep's traps all live there. Nil when no load
    // is showing.
    WaveformLoadingIndicator *_loadingIndicator;
    CALayer                 *_placeholderLayer;
    // The centerline past the track's ends: two hairline segments continuing
    // the waveform's silence baseline across the off-track space — left of
    // the content before the start (played styling, it sits on the playhead's
    // played side) and right of it near the end (unplayed). Repositioned with
    // every host translation; hidden without a waveform.
    CALayer                 *_leadingBaseline;
    CALayer                 *_trailingBaseline;
    // The flick's decay: progress/second, stepped by a display link until it
    // falls below the settle speed — only then does the seek commit.
    CADisplayLink           *_momentumLink;
    CGFloat                 _momentumVelocity;
    CFTimeInterval          _momentumLastTime;
    // The scrub-tick haptic and the last virtual-x bucket that fired it.
    UISelectionFeedbackGenerator *_scrubHaptics;
    NSInteger               _lastTickBucket;
    // Kept so a content reset can cancel an in-flight drag; see
    // resetWaveformContentState.
    UIPanGestureRecognizer  *_panRecognizer;
    // The settled fast path: the envelope baked into one bitmap, shown by two
    // image layers — unplayed across the full width, played stacked on top of
    // it (the same compositing order as the live tree's played clip) and
    // cropped by contentsRect. Non-nil _bakedHost means the fast path is in
    // and _rendererHost is hidden. The generation invalidates in-flight bakes.
    CALayer                 *_bakedHost;
    CALayer                 *_bakedUnplayed;
    CALayer                 *_bakedPlayed;
    NSUInteger              _bakeGeneration;
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
    // The host extends several screen widths past both edges.
    self.clipsToBounds = YES;

    _rendererHost = [[CALayer alloc] init];
    _rendererHost.geometryFlipped = YES;
    _rendererHost.anchorPoint = CGPointZero;
    _rendererHost.bounds = [self virtualBounds];
    _rendererHost.position = CGPointZero;
    [self.layer addSublayer:_rendererHost];

    _leadingBaseline = [CALayer layer];
    _leadingBaseline.hidden = YES;
    [self.layer addSublayer:_leadingBaseline];
    _trailingBaseline = [CALayer layer];
    _trailingBaseline.hidden = YES;
    [self.layer addSublayer:_trailingBaseline];

    _panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                             action:@selector(handlePan:)];
    [self addGestureRecognizer:_panRecognizer];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    __weak WaveformScrubberView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitDisplayScale.class]
                      withHandler:^(id<UITraitEnvironment> env, UITraitCollection *previous) {
                          [weakSelf traitsDidChange:previous];
                      }];
}

// Needed because the momentum link holds only the weak proxy; without the
// invalidate a link outliving the view would fire no-ops at display rate
// forever.
- (void)dealloc {
    [_momentumLink invalidate];
}

- (BOOL)isScrubbing {
    return _isScrubbing;
}

- (BOOL)isShowingBakedWaveform {
    return _bakedHost != nil;
}

#pragma mark - Renderer lifecycle

- (CGFloat)displayScale {
    return VibeBackingScaleOrDefault(self.traitCollection.displayScale);
}

// The zoomed content width the renderer draws into; 0 before layout.
- (CGFloat)virtualWidth {
    return self.bounds.size.width / kWaveformVisibleFraction;
}

- (CGRect)virtualBounds {
    return CGRectMake(0, 0, [self virtualWidth], self.bounds.size.height);
}

- (void)installRendererIfNeeded {
    if (_renderer) {
        return;
    }
    // The app default style (Oversampling Detailed x4), same as the mac's —
    // no iOS style picker yet. The registry fallback keeps this safe if the
    // identifier is ever renamed.
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT];
    Class rendererClass = [WaveformRendererRegistry rendererClassForIdentifier:style];
    if (!rendererClass) {
        return;
    }
    _rendererHost.contentsScale = [self displayScale];
    // The renderer reads parentLayer.bounds, so the host must be at virtual
    // size before it exists.
    _rendererHost.bounds = [self virtualBounds];
    _renderer = [[rendererClass alloc] initWithLayer:_rendererHost
                                              bounds:[self virtualBounds]
                                              isDark:self.isDark];
    [self updateBaselineColors];
}

// The baseline segments take the waveform's own midline alpha per side, so
// they join the silence hairline with no visible seam.
- (void)updateBaselineColors {
    if (![_renderer isKindOfClass:DetailedAudioWaveformRenderer.class]) {
        return;
    }
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)_renderer;
    UIColor *base = self.isDark ? UIColor.whiteColor : UIColor.blackColor;
    _leadingBaseline.backgroundColor =
            [base colorWithAlphaComponent:[renderer baselineAlphaForPlayed:YES]].CGColor;
    _trailingBaseline.backgroundColor =
            [base colorWithAlphaComponent:[renderer baselineAlphaForPlayed:NO]].CGColor;
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

// Host translation and played-clip width move in one transaction so the
// played/unplayed boundary sits exactly at the view's center every frame:
// position.x + progress * virtualWidth == centerX. On the baked fast path the
// same frame is pure texture work — translate the host, crop the played
// image — with the live masked tree hidden and untouched.
- (void)applyScrollAndProgress {
    CGFloat virtualWidth = [self virtualWidth];
    if (!_renderer || virtualWidth <= 0) {
        return;
    }
    // The timer writers push raw position/duration, which can land a hair
    // past 1.0 at track end; an out-of-unit contentsRect smears the baked
    // image's edge pixels across the excess.
    CGFloat progress = MAX(0.0, MIN(1.0, _progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGPoint origin = CGPointMake(self.bounds.size.width / 2 - progress * virtualWidth, 0);
    if (_bakedHost) {
        _bakedHost.position = origin;
        _bakedPlayed.bounds = CGRectMake(0, 0, progress * virtualWidth, _bakedHost.bounds.size.height);
        _bakedPlayed.contentsRect = CGRectMake(0, 0, progress, 1);
    }
    else {
        _rendererHost.position = origin;
        [_renderer updateProgress:progress waveform:self.waveform.waveform];
    }
    // kVibeMidlineHeight and the midY placement match the settled hairline's
    // pixel rows exactly, in both the live tree's flipped space and the bake.
    CGFloat midY = self.bounds.size.height / 2;
    CGFloat trailingStart = origin.x + virtualWidth;
    CGFloat trailingWidth = self.bounds.size.width - trailingStart;
    BOOL show = self.waveform != nil;
    _leadingBaseline.hidden = !show || origin.x <= 0;
    _trailingBaseline.hidden = !show || trailingWidth <= 0;
    if (!_leadingBaseline.hidden) {
        _leadingBaseline.frame = CGRectMake(0, midY - kVibeMidlineHeight / 2, origin.x, kVibeMidlineHeight);
    }
    if (!_trailingBaseline.hidden) {
        _trailingBaseline.frame = CGRectMake(trailingStart, midY - kVibeMidlineHeight / 2,
                                             trailingWidth, kVibeMidlineHeight);
    }
    [CATransaction commit];
}

#pragma mark - Progress

- (NSUInteger)progressBucket {
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)([self virtualWidth] * [self displayScale]));
    return static_cast<NSUInteger>(_progress * steps);
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

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

- (void)resetWaveformContentState {
    [self teardownBakedWaveform];
    [self cancelMomentum];
    // A drag straddling a track change must not keep scrubbing the new
    // track from the old track's start progress: cancel the touch outright
    // (the toggle fires handlePan's cancelled branch), so the finger has to
    // re-begin against the new content.
    if (_panRecognizer.state == UIGestureRecognizerStateBegan
            || _panRecognizer.state == UIGestureRecognizerStateChanged) {
        _panRecognizer.enabled = NO;
        _panRecognizer.enabled = YES;
    }
    _isScrubbing = NO;
    self.waveform = nil;
    // Force the repaint even when the bucket is already 0, so the reset
    // always re-parks the translation.
    _progressTracker = NSUIntegerMax;
    self.progress = 0;
}

- (void)prepareForWaveformLoad {
    [self hideLoadingIndicator];
    [self hideEmptyPlaceholder];
    [self resetWaveformContentState];
    [self installRendererIfNeeded];
    [self drawWaveformSettled];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [self showWaveform:waveform animated:YES];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated {
    // Data arrival is what genuinely ends the shimmer and empty
    // presentations — the audio open landing does not (its decode may still
    // be streaming over the network), so owners no longer hide the line;
    // this does. The download fill is NOT ended here: a disk-cached waveform
    // arrives without materializing the audio file, so the provider can still
    // be downloading it — the fill then rides over the waveform as the only
    // sign of that, and it comes down with its monitor (the open landing or
    // the error path clears it via setLoadingProgress:-1).
    [self hideLoadingShimmer];
    [self hideEmptyPlaceholder];
    // A fresh view may receive data before anyone called
    // prepareForWaveformLoad (per-page cells hydrate directly); the renderer
    // must exist before the draw.
    [self installRendererIfNeeded];
    // New data retargets the morph, so the live tree takes back over until it
    // settles again — a mid-load delivery keeps growing bars, and the bake
    // lands once deliveries stop.
    [self teardownBakedWaveform];
    self.waveform = waveform;
    if (animated) {
        [self drawWaveform];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
    else {
        // Nothing to wait out: the bars are already on the target, so the bake
        // is scheduled for the next turn of the main queue rather than for
        // after a morph that will not run. The live tree stands in only until
        // it lands.
        [self drawWaveformSettled];
        [self scheduleEnvelopeBakeAfter:0];
    }
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
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)_renderer;
    CGFloat scale = [self displayScale];
    // A CALayer whose contents exceed the GPU texture ceiling renders BLANK,
    // and the virtual width crosses 16384px on wide iPad windows (view width
    // / kWaveformVisibleFraction × scale). Bake at a reduced scale instead —
    // the layers' default resize gravity stretches it back, softening the
    // bars slightly, which beats an invisible waveform. A width that cannot
    // fit even at 1x would need a ~3250pt view; bail to the live tree if it
    // ever happens.
    static const CGFloat kMaxBakeImagePixels = 16384;
    if (size.width * scale > kMaxBakeImagePixels) {
        scale = kMaxBakeImagePixels / size.width;
        if (scale < 1) {
            return;
        }
    }
    // Samples come out on the main thread — the same access updateWaveform:
    // performs — so only the pixel work leaves it.
    NSData *samples = [renderer envelopeSamplesForWaveform:self.waveform.waveform];
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef image = [renderer newEnvelopeImageForSize:size scale:scale samples:samples];
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
    if (!image || generation != _bakeGeneration ||
        !CGSizeEqualToSize(size, [self virtualBounds].size)) {
        return;
    }
    CGFloat unplayedOpacity = [(DetailedAudioWaveformRenderer *)_renderer unplayedOverPlayedOpacity];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // No geometryFlipped here: the bake draws in CG's y-up space, whose top
    // row lands at the layer's top, matching what the flipped live tree shows.
    _bakedHost = [CALayer layer];
    _bakedHost.anchorPoint = CGPointZero;
    _bakedHost.bounds = (CGRect){CGPointZero, size};
    _bakedUnplayed = [CALayer layer];
    _bakedUnplayed.anchorPoint = CGPointZero;
    _bakedUnplayed.frame = (CGRect){CGPointZero, size};
    _bakedUnplayed.contents = (__bridge id)image;
    _bakedUnplayed.opacity = (float)unplayedOpacity;
    [_bakedHost addSublayer:_bakedUnplayed];
    _bakedPlayed = [CALayer layer];
    _bakedPlayed.anchorPoint = CGPointZero;
    _bakedPlayed.position = CGPointZero;
    _bakedPlayed.contents = (__bridge id)image;
    [_bakedHost addSublayer:_bakedPlayed];
    [self.layer insertSublayer:_bakedHost above:_rendererHost];
    _rendererHost.hidden = YES;
    [CATransaction commit];
    [self applyScrollAndProgress];
}

- (void)showLoadingIndicator {
    if (_loadingIndicator) {
        return;
    }
    [self hideEmptyPlaceholder];
    [self resetWaveformContentState];
    if (_renderer) {
        [self drawWaveform];
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

- (void)showEmptyPlaceholder {
    if (_placeholderLayer) {
        return;
    }
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    if (_renderer) {
        [self drawWaveform];
    }
    CALayer *line = [CALayer layer];
    line.contentsScale = [self displayScale];
    [self.layer addSublayer:line];
    _placeholderLayer = line;
    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - kVibeMidlineHeight / 2,
                                        self.bounds.size.width, kVibeMidlineHeight);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    UIColor *base = self.isDark ? [UIColor whiteColor] : [UIColor blackColor];
    _placeholderLayer.backgroundColor = [base colorWithAlphaComponent:kVibeInertMidlineAlpha].CGColor;
}

#pragma mark - Touch scrubbing

// Direct manipulation with momentum: the drag moves the content 1:1 under
// the fixed center playhead, a flick keeps it moving with UIScrollView's
// deceleration, and the seek commits only once the content settles. A
// cancelled drag just stops; the next progress push restores the true
// position.
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.waveform) {
        return;
    }
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            // A touch mid-deceleration catches the moving content, exactly
            // like grabbing a coasting scroll view.
            [self cancelMomentum];
            _isScrubbing = YES;
            _dragStartProgress = _progress;
            _scrubHaptics = [[UISelectionFeedbackGenerator alloc] init];
            [_scrubHaptics prepare];
            _lastTickBucket = [self tickBucket];
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat virtualWidth = [self virtualWidth];
            if (virtualWidth <= 0) {
                break;
            }
            CGFloat p = _dragStartProgress - [pan translationInView:self].x / virtualWidth;
            [self scrubToProgress:p];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            CGFloat virtualWidth = [self virtualWidth];
            CGFloat vx = [pan velocityInView:self].x;
            if (virtualWidth <= 0 || fabs(vx) < kMomentumMinimumFlick) {
                [self settleScrub];
                break;
            }
            // Content follows the finger, so content velocity is the finger's;
            // progress runs against x. The weak proxy keeps a mid-momentum
            // link from pinning a recycled cell's view alive; dealloc
            // invalidates it.
            _momentumVelocity = -vx / virtualWidth;
            _momentumLastTime = CACurrentMediaTime();
            _momentumLink = [CADisplayLink displayLinkWithTarget:[VibeWeakProxy proxyWithTarget:self]
                                                        selector:@selector(momentumTick:)];
            [_momentumLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            break;
        }
        default:
            [self cancelMomentum];
            _isScrubbing = NO;
            _scrubHaptics = nil;
            break;
    }
}

// The shared scrub step for finger and momentum: clamp, repaint, and tick
// the haptic when a waveform line crosses the fixed playhead.
- (void)scrubToProgress:(CGFloat)progress {
    _progress = MAX(0.0, MIN(1.0, progress));
    // The same device-pixel gate as setProgress:. It matters most in the
    // pre-bake window, where every repaint re-composites the masked live
    // tree offscreen in full.
    NSUInteger p = [self progressBucket];
    if (_progressTracker != p) {
        _progressTracker = p;
        [self applyScrollAndProgress];
    }
    NSInteger bucket = [self tickBucket];
    if (bucket != _lastTickBucket) {
        _lastTickBucket = bucket;
        [_scrubHaptics selectionChanged];
        [_scrubHaptics prepare];
    }
}

- (NSInteger)tickBucket {
    return (NSInteger)floor(_progress * [self virtualWidth] / kScrubTickSpacing);
}

- (void)momentumTick:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = now - _momentumLastTime;
    _momentumLastTime = now;

    [self scrubToProgress:_progress + _momentumVelocity * dt];
    _momentumVelocity *= pow(kDecelerationPerMillisecond, dt * 1000.0);

    BOOL hitEdge = (_progress <= 0.0 || _progress >= 1.0);
    BOOL settled = fabs(_momentumVelocity) * [self virtualWidth] < kMomentumSettleSpeed;
    if (hitEdge || settled) {
        [self settleScrub];
    }
}

// The scrub is over — by settle, edge, or a no-flick release — so the seek
// commits and the progress writers take back over.
- (void)settleScrub {
    [self cancelMomentum];
    _isScrubbing = NO;
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didSeek:(float)_progress];
}

- (void)cancelMomentum {
    [_momentumLink invalidate];
    _momentumLink = nil;
    _momentumVelocity = 0;
}

// A tap nudges to the tapped point within the visible window.
- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (!self.waveform || tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return;
    }
    CGFloat centerX = self.bounds.size.width / 2;
    CGFloat p = _progress + ([tap locationInView:self].x - centerX) / virtualWidth;
    // A tap mid-deceleration claims the transport: left running, the momentum
    // would settle later and commit a second seek over this one.
    [self cancelMomentum];
    _isScrubbing = NO;
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, p))];
}

#pragma mark - Layout and appearance

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect virtualBounds = [self virtualBounds];
    BOOL sizeChanged = !CGSizeEqualToSize(_rendererHost.bounds.size, virtualBounds.size);
    if (sizeChanged) {
        // The bitmap is baked for the old size; the live tree carries the
        // resize and the bake re-lands at the new one.
        [self teardownBakedWaveform];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.bounds = virtualBounds;
    [CATransaction commit];
    [self applyScrollAndProgress];
    if (sizeChanged && _renderer) {
        // Sync geometry even with no waveform, as the mac view does, so a
        // mid-collapse morph rebuilds at the new size.
        [self drawWaveform];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
    if (sizeChanged) {
        [self layoutLoadingLayer];
        [self layoutPlaceholderLayer];
    }
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
    }
    if (styleChanged) {
        [_renderer updateColors:self.isDark];
        [_loadingIndicator updateColorsForDark:self.isDark];
        [self updatePlaceholderColor];
        [self updateBaselineColors];
    }
    if (scaleChanged || styleChanged) {
        [self applyScrollAndProgress];
        [self scheduleEnvelopeBakeAfter:kEnvelopeBakeDelay];
    }
}

@end
