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
#import "AppSettings.h"

// Fraction of the track visible across the view: the DJ zoom level, and the
// one knob the whole scrubber's scale hangs off — a preference or a pinch
// gesture would drive this and nothing else. The renderer draws the full track
// at width / fraction (about 2 screens) and that is the scroll's content
// width, so the play position sits at the view's horizontal center. Raising it
// shows more time and, as a free consequence, shrinks the virtual layer tree.
static const CGFloat kWaveformVisibleFraction = 0.48;

// How far past the content's edges the baseline hairline segments extend, as a
// multiple of the view's width. They have to still cover the exposed space at
// full bounce, which is centerX plus the bounce — and the bounce measures
// about 0.27 of a width in both orientations, because one finger travel cannot
// reach the loose end of UIScrollView's curve on a screen this narrow. So 0.8
// is the floor and this is margin.
static const CGFloat kBaselineOverhangWidths = 2.0;

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

@interface WaveformScrubberView () <UIScrollViewDelegate>
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // The scroll that carries the content. Its contentSize is the virtual
    // (zoomed) width and its insets are half a view on each side, so the
    // content rests under the view's center at both ends of the track and
    // UIKit supplies the band, the spring and the deceleration. Everything
    // that scrolls is a sublayer of ITS layer; the loading indicator and the
    // empty placeholder stay in self.layer, which does not move.
    UIScrollView            *_scroll;
    // The renderers' parent layer. geometryFlipped gives its sublayers the
    // bottom-left-origin space the shared renderer math was written for (the
    // mac view is a non-flipped layer-hosting NSView), so SonicCirrus's
    // top/mirror layout and the Detailed gradients render identically with
    // zero shared-code change. Its bounds are the virtual (zoomed) size, not
    // the view's, and it sits at content origin.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    // The loading control, shared with the mac view: its own layers, its
    // determinate fill and the sweep's traps all live there. Nil when no load
    // is showing.
    WaveformLoadingIndicator *_loadingIndicator;
    CALayer                 *_placeholderLayer;
    // The centerline past the track's ends: two hairline segments continuing
    // the waveform's silence baseline across the off-track space — left of
    // the content before the start (played styling, it sits on the playhead's
    // played side) and right of it near the end (unplayed). Fixed-size, glued
    // to the content's edges, so they ride the scroll rather than being
    // resized to the gap every frame; hidden without a waveform.
    CALayer                 *_leadingBaseline;
    CALayer                 *_trailingBaseline;
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
    _scroll.scrollEnabled = NO;
    [self addSubview:_scroll];

    _rendererHost = [[CALayer alloc] init];
    _rendererHost.geometryFlipped = YES;
    _rendererHost.anchorPoint = CGPointZero;
    _rendererHost.bounds = [self virtualBounds];
    _rendererHost.position = CGPointZero;
    [_scroll.layer addSublayer:_rendererHost];

    _leadingBaseline = [CALayer layer];
    _leadingBaseline.hidden = YES;
    [_scroll.layer addSublayer:_leadingBaseline];
    _trailingBaseline = [CALayer layer];
    _trailingBaseline.hidden = YES;
    [_scroll.layer addSublayer:_trailingBaseline];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    __weak WaveformScrubberView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitDisplayScale.class]
                      withHandler:^(id<UITraitEnvironment> env, UITraitCollection *previous) {
                          [weakSelf traitsDidChange:previous];
                      }];
}

- (BOOL)isScrubbing {
    // The whole content motion, finger and coast and bounce alike: the span
    // over which the progress writers must keep off the scroll.
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
    [self layoutBaselines];
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
    }
    else {
        [_renderer updateProgress:progress waveform:self.waveform.waveform];
    }
    [CATransaction commit];
}

// The off-track hairlines, placed once per layout rather than resized to the
// gap every frame: fixed segments glued to the content's edges ride the scroll
// and the bounce for free. kVibeMidlineHeight and the midY placement match the
// settled hairline's pixel rows exactly.
- (void)layoutBaselines {
    CGFloat overhang = self.bounds.size.width * kBaselineOverhangWidths;
    CGFloat y = self.bounds.size.height / 2 - kVibeMidlineHeight / 2;
    BOOL show = self.waveform != nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _leadingBaseline.hidden = !show;
    _trailingBaseline.hidden = !show;
    _leadingBaseline.frame = CGRectMake(-overhang, y, overhang, kVibeMidlineHeight);
    _trailingBaseline.frame = CGRectMake([self virtualWidth], y, overhang, kVibeMidlineHeight);
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

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

- (void)resetWaveformContentState {
    [self teardownBakedWaveform];
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
    _scroll.contentOffset = CGPointMake([self contentOffsetForProgress:0], 0);
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
    _bakedHost.position = CGPointZero;      // content origin; the scroll moves it
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
    [_scroll.layer insertSublayer:_bakedHost above:_rendererHost];
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

// Direct manipulation, UIKit's: the drag moves the content 1:1 under the fixed
// center playhead, a flick coasts, both ends give and spring back, and the
// seek commits as soon as the content reaches the point it will settle on. A
// cancelled drag just stops; the next progress push restores the true
// position.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (self.isScrubbing) {
        _progress = MAX(0.0, MIN(1.0, [self progressForContentOffset:scrollView.contentOffset.x]));
        _progressTracker = [self progressBucket];
        NSInteger bucket = [self tickBucket];
        if (bucket != _lastTickBucket) {
            _lastTickBucket = bucket;
            CFTimeInterval now = CACurrentMediaTime();
            if (now - _lastTickTime >= kScrubTickMinInterval) {
                _lastTickTime = now;
                [_scrubHaptics impactOccurredWithIntensity:kScrubTickIntensity];
                [_scrubHaptics prepare];
            }
        }
    }
    [self applyPlayedClip];
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
    // would settle later and commit a second seek over this one.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _seekPending = NO;
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
    _scroll.frame = self.bounds;
    // Half a view of inset on each side is what parks the content under the
    // center at both ends of the track instead of against the view's edges.
    CGFloat centerX = self.bounds.size.width / 2;
    _scroll.contentInset = UIEdgeInsetsMake(0, centerX, 0, centerX);
    _scroll.contentSize = CGSizeMake(virtualBounds.size.width, self.bounds.size.height);
    _rendererHost.bounds = virtualBounds;
    [CATransaction commit];
    [self layoutBaselines];
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
