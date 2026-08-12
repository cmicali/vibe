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

@interface WaveformScrubberView ()
@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;
@end

@implementation WaveformScrubberView {
    // The renderers' parent layer. geometryFlipped gives its sublayers the
    // bottom-left-origin space the shared renderer math was written for (the
    // mac view is a non-flipped layer-hosting NSView), so SonicCirrus's
    // top/mirror layout and the Detailed gradients render identically with
    // zero shared-code change.
    CALayer                 *_rendererHost;
    AudioWaveformRenderer   *_renderer;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    BOOL                    _isScrubbing;
    CAGradientLayer         *_loadingLayer;
    CALayer                 *_placeholderLayer;
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

    _rendererHost = [[CALayer alloc] init];
    _rendererHost.geometryFlipped = YES;
    _rendererHost.frame = self.bounds;
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

- (void)installRendererIfNeeded {
    if (_renderer) {
        return;
    }
    // Phase 1 hard-wires the SoundCloud look — no iOS style picker yet. The
    // registry fallback keeps this safe if the style is ever renamed.
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:@"sonic_cirrus"];
    Class rendererClass = [WaveformRendererRegistry rendererClassForIdentifier:style];
    if (!rendererClass) {
        return;
    }
    _rendererHost.contentsScale = [self displayScale];
    _renderer = [[rendererClass alloc] initWithLayer:_rendererHost
                                              bounds:self.bounds
                                              isDark:self.isDark];
}

- (void)drawWaveform {
    [_renderer updateWaveform:self.bounds progress:_progress waveform:self.waveform.waveform];
}

- (void)updateRendererProgress {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_renderer updateProgress:_progress waveform:self.waveform.waveform];
    [CATransaction commit];
}

#pragma mark - Progress

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    // Repaint whenever the playhead crosses a device pixel; same gate as the
    // mac view, fed from the trait collection instead of the window.
    NSUInteger steps = MAX((NSUInteger)1, (NSUInteger)(self.bounds.size.width * [self displayScale]));
    NSUInteger p = static_cast<NSUInteger>(progress * steps);
    if (_progressTracker != p) {
        _progressTracker = p;
        [self updateRendererProgress];
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
    [_renderer setHoverHighlightX:-1];
    _isScrubbing = NO;
    self.waveform = nil;
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

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.waveform) {
        return;
    }
    CGFloat x = [pan locationInView:self].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _isScrubbing = YES;
            [_renderer setHoverHighlightX:x];
            break;
        case UIGestureRecognizerStateChanged:
            [_renderer setHoverHighlightX:x];
            break;
        case UIGestureRecognizerStateEnded: {
            _isScrubbing = NO;
            [_renderer setHoverHighlightX:-1];
            [self seekToX:x];
            break;
        }
        default:
            _isScrubbing = NO;
            [_renderer setHoverHighlightX:-1];
            break;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (!self.waveform || tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    [self seekToX:[tap locationInView:self].x];
}

- (void)seekToX:(CGFloat)x {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) {
        return;
    }
    float p = (float)MAX(0.0, MIN(1.0, x / width));
    [self.delegate waveformScrubberView:self didSeek:p];
}

#pragma mark - Layout and appearance

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL sizeChanged = !CGSizeEqualToSize(_rendererHost.frame.size, self.bounds.size);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rendererHost.frame = self.bounds;
    [CATransaction commit];
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
        [self updateRendererProgress];
        if (_loadingLayer) {
            _loadingLayer.colors = [self shimmerColors];
        }
        [self updatePlaceholderColor];
    }
}

@end
