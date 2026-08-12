//
//  WaveformScrubberView.mm
//  Vibe (iOS)
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "WaveformRendererRegistry.h"
#import "UIView+DarkMode.h"
#import "AppSettings.h"

// Fraction of the track visible across the view: the DJ zoom level. The
// renderer draws the full track at width / fraction and the host layer is
// translated so the play position sits at the view's horizontal center.
static const CGFloat kWaveformVisibleFraction = 0.15;

// Momentum: the per-millisecond deceleration (higher friction than
// UIScrollView's 0.998 normal rate, so a throw settles noticeably faster —
// this is a scrubber, not a scroll view), the flick floor below which a
// release settles immediately, and the speed (in view points/second of
// content motion) at which a decelerating scroll stops and commits the seek.
static const CGFloat kDecelerationPerMillisecond = 0.994;
static const CGFloat kMomentumMinimumFlick = 60.0;
static const CGFloat kMomentumSettleSpeed = 25.0;

// One haptic tick per this many points of virtual (zoomed) travel — the
// waveform's lines clicking past the fixed playhead.
static const CGFloat kScrubTickSpacing = 8.0;

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
    CAGradientLayer         *_loadingLayer;
    CALayer                 *_placeholderLayer;
    // The flick's decay: progress/second, stepped by a display link until it
    // falls below the settle speed — only then does the seek commit.
    CADisplayLink           *_momentumLink;
    CGFloat                 _momentumVelocity;
    CFTimeInterval          _momentumLastTime;
    // The scrub-tick haptic and the last virtual-x bucket that fired it.
    UISelectionFeedbackGenerator *_scrubHaptics;
    NSInteger               _lastTickBucket;
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

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
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
    return _isScrubbing;
}

#pragma mark - Renderer lifecycle

- (CGFloat)displayScale {
    CGFloat scale = self.traitCollection.displayScale;
    return scale > 0 ? scale : kVibeDefaultBackingScale;
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
}

- (void)drawWaveform {
    [_renderer updateWaveform:[self virtualBounds] progress:_progress waveform:self.waveform.waveform];
    [self applyScrollAndProgress];
}

// Host translation and played-clip width move in one transaction so the
// played/unplayed boundary sits exactly at the view's center every frame:
// position.x + progress * virtualWidth == centerX.
- (void)applyScrollAndProgress {
    CGFloat virtualWidth = [self virtualWidth];
    if (!_renderer || virtualWidth <= 0) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.position = CGPointMake(self.bounds.size.width / 2 - _progress * virtualWidth, 0);
    [_renderer updateProgress:_progress waveform:self.waveform.waveform];
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
    [self cancelMomentum];
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
    [self drawWaveform];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    // A fresh view may receive data before anyone called
    // prepareForWaveformLoad (per-page cells hydrate directly); the renderer
    // must exist before the draw.
    [self installRendererIfNeeded];
    self.waveform = waveform;
    [self drawWaveform];
}

- (void)showLoadingIndicator {
    if (_loadingLayer) {
        return;
    }
    [self hideEmptyPlaceholder];
    [self resetWaveformContentState];
    if (_renderer) {
        [self drawWaveform];
    }
    CAGradientLayer *shimmer = [CAGradientLayer layer];
    shimmer.contentsScale = [self displayScale];
    shimmer.startPoint = CGPointMake(0, 0.5);
    shimmer.endPoint = CGPointMake(1, 0.5);
    shimmer.colors = [self shimmerColors];
    [self.layer addSublayer:shimmer];
    _loadingLayer = shimmer;
    [self layoutLoadingLayer];
}

- (NSArray *)shimmerColors {
    UIColor *base = self.isDark ? [UIColor whiteColor] : [UIColor blackColor];
    return @[
            (id)[base colorWithAlphaComponent:0].CGColor,
            (id)[base colorWithAlphaComponent:0.55].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

- (void)layoutLoadingLayer {
    if (!_loadingLayer) {
        return;
    }
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2;
    CGFloat bandWidth = MAX(width * 0.35, 40);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _loadingLayer.frame = CGRectMake(0, midY - 1, bandWidth, 2);
    [CATransaction commit];

    // Reinstall the sweep only when its endpoints change; see the mac view's
    // note about live resize restarting the animation every frame.
    NSNumber *fromValue = @(-bandWidth / 2);
    NSNumber *toValue = @(width + bandWidth / 2);
    CABasicAnimation *current = (CABasicAnimation *)[_loadingLayer animationForKey:@"sweep"];
    if ([current isKindOfClass:CABasicAnimation.class] &&
        [current.fromValue isEqual:fromValue] && [current.toValue isEqual:toValue]) {
        return;
    }
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweep.fromValue = fromValue;
    sweep.toValue = toValue;
    sweep.duration = 1.2;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (current) {
        CFTimeInterval now = [_loadingLayer convertTime:CACurrentMediaTime() fromLayer:nil];
        CFTimeInterval elapsed = current.beginTime > 0 ? MAX(now - current.beginTime, 0) : 0;
        sweep.timeOffset = fmod(elapsed + current.timeOffset, sweep.duration);
    }
    [_loadingLayer addAnimation:sweep forKey:@"sweep"];
}

- (void)hideLoadingIndicator {
    [_loadingLayer removeAllAnimations];
    [_loadingLayer removeFromSuperlayer];
    _loadingLayer = nil;
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
    _placeholderLayer.frame = CGRectMake(0, midY - 1, self.bounds.size.width, 2);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    UIColor *base = self.isDark ? [UIColor whiteColor] : [UIColor blackColor];
    _placeholderLayer.backgroundColor = [base colorWithAlphaComponent:0.275].CGColor;
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
            // progress runs against x.
            _momentumVelocity = -vx / virtualWidth;
            _momentumLastTime = CACurrentMediaTime();
            _momentumLink = [CADisplayLink displayLinkWithTarget:self
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
    _progressTracker = [self progressBucket];
    [self applyScrollAndProgress];
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
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, p))];
}

#pragma mark - Layout and appearance

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect virtualBounds = [self virtualBounds];
    BOOL sizeChanged = !CGSizeEqualToSize(_rendererHost.bounds.size, virtualBounds.size);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.bounds = virtualBounds;
    [CATransaction commit];
    [self applyScrollAndProgress];
    if (sizeChanged && _renderer) {
        // Sync geometry even with no waveform, as the mac view does, so a
        // mid-collapse morph rebuilds at the new size.
        [self drawWaveform];
    }
    if (sizeChanged) {
        [self layoutLoadingLayer];
        [self layoutPlaceholderLayer];
    }
}

static void applyContentsScale(CALayer *layer, CGFloat scale) {
    if (!layer) return;
    layer.contentsScale = scale;
    applyContentsScale(layer.mask, scale);
    for (CALayer *sublayer in layer.sublayers) {
        applyContentsScale(sublayer, scale);
    }
}

- (void)traitsDidChange:(UITraitCollection *)previous {
    if (previous.displayScale != self.traitCollection.displayScale) {
        applyContentsScale(self.layer, [self displayScale]);
        [_renderer backingScaleDidChange];
    }
    if (previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [_renderer updateColors:self.isDark];
        [self applyScrollAndProgress];
        if (_loadingLayer) {
            _loadingLayer.colors = [self shimmerColors];
        }
        [self updatePlaceholderColor];
    }
}

@end
