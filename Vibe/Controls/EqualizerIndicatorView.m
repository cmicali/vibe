//
//  EqualizerIndicatorView.m
//  Vibe
//
//  See the header for why this is shared. The #if blocks are only the
//  platform's names for "lay out", "the appearance changed", "I moved to a
//  window" and "alpha".
//

#import "EqualizerIndicatorView.h"

#import "EqualizerActivityRules.h"
#import "EqualizerAnimationMath.h"
#import "VibeWeakProxy.h"
#import <QuartzCore/QuartzCore.h>
#if DEBUG
#import <stdatomic.h>
#endif

#if TARGET_OS_OSX
#import "NSView+DarkMode.h"
#else
#import "UIView+DarkMode.h"
#endif

enum { kBarCount = 5 };
static const CGFloat kBarGap = 1.5;
// A live analyzer publishes much faster than this. Past this point the source
// has stalled, so decaying is more honest than holding an old musical pose.
static const CFTimeInterval kLevelSnapshotStaleSeconds = 0.5;
static NSString *const kLevelScaleAnimationKey = @"equalizerLevelScale";

static CAMediaTimingFunction *VibeEqualizerEaseOutTimingFunction(void) {
    static CAMediaTimingFunction *timingFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    });
    return timingFunction;
}

#if DEBUG
static _Atomic(uint64_t) sActiveDisplayLinks;
static _Atomic(uint64_t) sTotalDisplayTicks;
static _Atomic(uint64_t) sTotalGeometryLayouts;
static _Atomic(uint64_t) sTotalTransformWrites;

static void VibeEqualizerDebugIncrement(_Atomic(uint64_t) *counter) {
    atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
}

static void VibeEqualizerDebugDisplayLinkStopped(void) {
    uint64_t previous = atomic_fetch_sub_explicit(&sActiveDisplayLinks, 1, memory_order_relaxed);
    NSCAssert(previous > 0, @"equalizer display-link count underflow");
}
#else
#define VibeEqualizerDebugIncrement(counter) ((void)0)
#define VibeEqualizerDebugDisplayLinkStopped() ((void)0)
#endif

@implementation EqualizerIndicatorView {
    NSArray<CALayer *> *_bars;
    // The paused pose, recomputed on every layout: the scale at which a bar is
    // as tall as it is wide. It is the floor the reactive path grows from, so
    // level 0 and "not playing" draw the identical row of dots.
    CGFloat             _collapsedScale;
    CADisplayLink      *_levelLink;
    float               _targetLevels[kBarCount];
    CGFloat             _lastAppliedScales[kBarCount];
    CFTimeInterval      _lastSnapshotTimestamp;
    uint64_t             _lastSnapshotSequence;
    CGRect               _laidOutBounds;
    BOOL                 _hasBarGeometry;
    // The source we currently hold demand against, or nil. Held rather than a
    // BOOL so a levelSource swap under a running link releases the OLD source
    // instead of leaving it producing for nobody.
    __weak id<EqualizerLevelSource> _levelsDeclaredTo;
    BOOL                 _hasDeclaredLevels;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
#if TARGET_OS_OSX
        self.wantsLayer = YES;
#endif
        NSMutableArray<CALayer *> *bars = [NSMutableArray arrayWithCapacity:kBarCount];
        for (NSUInteger i = 0; i < kBarCount; i++) {
            CALayer *bar = [CALayer layer];
            // A centered anchor, so the bars grow and shrink symmetrically
            // around the vertical midline, like the app icon's waveform.
            bar.anchorPoint = CGPointMake(0.5, 0.5);
            // NSNull permanently disables implicit animations for geometry,
            // color and model-transform writes. Explicit level animations are
            // installed only when a new snapshot materially changes a target.
            bar.actions = @{
                @"backgroundColor": NSNull.null,
                @"bounds": NSNull.null,
                @"cornerRadius": NSNull.null,
                @"position": NSNull.null,
                @"transform": NSNull.null,
            };
            [self.layer addSublayer:bar];
            [bars addObject:bar];
            _lastAppliedScales[i] = NAN;
        }
        _bars = bars;
#if TARGET_OS_OSX
        self.alphaValue = 0.8;
#else
        self.alpha = 0.8;
#endif
#if !TARGET_OS_OSX
        // The iOS twin of viewDidChangeEffectiveAppearance.
        __weak EqualizerIndicatorView *weakSelf = self;
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class]
                          withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [weakSelf applyAppearanceColor];
        }];
#endif
        [self applyAppearanceColor];
    }
    return self;
}

- (void)setBarColor:(VibeColor *)barColor {
    _barColor = barColor;
    [self applyAppearanceColor];
}

- (void)applyAppearanceColor {
    VibeColor *fallback = self.isDark ? [VibeColor whiteColor] : [VibeColor blackColor];
    CGColorRef color = (_barColor ?: fallback).CGColor;
    for (CALayer *bar in _bars) {
        bar.backgroundColor = color;
    }
}

#if TARGET_OS_OSX
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyAppearanceColor];
}
#endif

// The paused pose: every bar collapsed to its own width, which with the pill
// corner radius makes it a circle — a row of dots. It is also level zero for
// live animation, so stopping the poll link settles to the same pose.
//
// Scaled from the bar width rather than a constant, because "as short as it
// goes" is a shape, not a number: the same view drawn at any size collapses to
// round dots instead of to stadiums or slivers.
- (CGFloat)collapsedScaleForBarWidth:(CGFloat)barWidth height:(CGFloat)height {
    return height > 0 ? MIN(1.0, barWidth / height) : 1.0;
}

- (void)layoutBars {
    CGRect bounds = self.bounds;
    if (_hasBarGeometry && CGRectEqualToRect(bounds, _laidOutBounds)) {
        return;
    }
    _hasBarGeometry = YES;
    _laidOutBounds = bounds;
    VibeEqualizerDebugIncrement(&sTotalGeometryLayouts);

    CGSize size = bounds.size;
    CGFloat availableWidth = MAX(0.0, size.width - kBarGap * (kBarCount - 1));
    CGFloat barWidth = availableWidth / (CGFloat)kBarCount;
    CGFloat height = MAX(0.0, size.height);
    CGFloat collapsed = [self collapsedScaleForBarWidth:barWidth height:height];
    _collapsedScale = collapsed;
    CGFloat minX = CGRectGetMinX(bounds);
    CGFloat minY = CGRectGetMinY(bounds);
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        bar.bounds = CGRectMake(0, 0, barWidth, height);
        bar.position = CGPointMake(minX + i * (barWidth + kBarGap) + barWidth / 2,
                                   minY + height / 2);
        bar.cornerRadius = barWidth / 2; // pill ends, like the icon's bars
    }
    [self applyBarScales];
    [self refreshActivity];
}

#if TARGET_OS_OSX
- (void)layout {
    [super layout];
    [self layoutBars];
}
#else
- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutBars];
}
#endif

- (void)setAudioOutputActive:(BOOL)audioOutputActive {
    if (_audioOutputActive == audioOutputActive) {
        return;
    }
    _audioOutputActive = audioOutputActive;
    // Only a light dim when paused: the collapse to dots is what says "not
    // playing" now, and dimming a row of dots as hard as it dimmed full-height
    // bars left almost nothing to see.
#if TARGET_OS_OSX
    self.alphaValue = audioOutputActive ? 1.0 : 0.8;
#else
    self.alpha = audioOutputActive ? 1.0 : 0.8;
#endif
    [self refreshActivity];
}

- (void)setPresentationVisible:(BOOL)presentationVisible {
    if (_presentationVisible == presentationVisible) {
        return;
    }
    _presentationVisible = presentationVisible;
    [self refreshActivity];
}

- (void)setHidden:(BOOL)hidden {
    if (self.hidden == hidden) {
        return;
    }
    [super setHidden:hidden];
    [self refreshActivity];
}

- (BOOL)isAudioReactive {
    return _levelLink != nil;
}

// The color is re-resolved here because attaching to a window can change the
// effective appearance without an appearance callback.
- (void)didMoveToWindowShared {
    [self applyAppearanceColor];
    [self refreshActivity];
}

#if TARGET_OS_OSX
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self didMoveToWindowShared];
}
#else
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self didMoveToWindowShared];
}
#endif

- (void)setLevelSource:(id<EqualizerLevelSource>)levelSource {
    if (_levelSource == levelSource) {
        return;
    }
    _levelSource = levelSource;
    _lastSnapshotSequence = 0;
    _lastSnapshotTimestamp = 0;
    for (NSUInteger i = 0; i < kBarCount; i++) {
        _targetLevels[i] = 0;
    }
    [self applyBarScales];
    [self refreshActivity];
}

- (VibeEqualizerActivityState)currentActivityState {
    CGSize size = self.bounds.size;
    return (VibeEqualizerActivityState){
        .audioOutputActive = _audioOutputActive,
        .presentationVisible = _presentationVisible && !self.hidden,
        .attachedToWindow = self.window != nil,
        .hasLevelSource = _levelSource != nil,
        .hasRenderableArea = size.width > kBarGap * (kBarCount - 1) && size.height > 0,
    };
}

- (void)refreshActivity {
    VibeEqualizerActivityState state = [self currentActivityState];
    if (VibeEqualizerShouldRun(state)) {
        [self startLevelLink];
        [self declareLevelsWanted:_levelLink != nil];
        return;
    }
    BOOL stopped = [self stopLevelLink];
    [self declareLevelsWanted:NO];
    if (_levelLink) {
        return;
    }
    state = [self currentActivityState];
    BOOL animateRelease = VibeEqualizerCanAnimateReleaseToDots(state);
    if (stopped && animateRelease) {
        [self animateReleaseToDots];
    }
    else if (!animateRelease) {
        [self applyBarScales];
    }
}

#pragma mark - Reactive bars

// Balances itself: a source is told YES once and NO once, and a swap tells the
// outgoing one NO before the incoming one YES, so a counting source stays exact.
- (void)declareLevelsWanted:(BOOL)wanted {
    id<EqualizerLevelSource> target = wanted ? _levelSource : nil;
    id<EqualizerLevelSource> current = _levelsDeclaredTo;
    if (_hasDeclaredLevels && current == nil) {
        NSAssert(NO, @"An EqualizerLevelSource deallocated while demand was active");
        _hasDeclaredLevels = NO;
    }
    if (target == current && _hasDeclaredLevels == (target != nil)) {
        return;
    }
    if (_hasDeclaredLevels) {
        NSAssert(current != nil, @"Equalizer level demand must have a source");
        [current equalizerLevelsWanted:NO];
        _hasDeclaredLevels = NO;
    }
    _levelsDeclaredTo = nil;
    if (target) {
        _levelsDeclaredTo = target;
        _hasDeclaredLevels = YES;
        [target equalizerLevelsWanted:YES];
    }
}

- (void)startLevelLink {
    if (_levelLink) {
        return;
    }
    // Through a weak proxy, because the link retains its target and a table
    // cell's indicator must still reach dealloc. This link only polls the
    // lower-rate snapshot and staleness clocks; Core Animation interpolates
    // material target changes at the display's cadence.
    //
    // The constructor is the one genuine platform difference: a mac link is
    // minted by the view it will draw for, since a display can come and go
    // under a window, while +displayLinkWithTarget:selector: is UIKit-only.
    id proxy = [VibeWeakProxy proxyWithTarget:self];
#if TARGET_OS_OSX
    _levelLink = [self displayLinkWithTarget:proxy selector:@selector(levelTick:)];
#else
    _levelLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(levelTick:)];
#endif
    if (!_levelLink) {
        return;
    }
    _levelLink.preferredFrameRateRange = CAFrameRateRangeMake(20, 30, 30);
    [_levelLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    VibeEqualizerDebugIncrement(&sActiveDisplayLinks);
}

- (BOOL)stopLevelLink {
    if (!_levelLink) {
        return NO;
    }
    [_levelLink invalidate];
    _levelLink = nil;
    VibeEqualizerDebugDisplayLinkStopped();
    _lastSnapshotTimestamp = 0;
    for (NSUInteger i = 0; i < kBarCount; i++) {
        _targetLevels[i] = 0;
    }
    return YES;
}

- (CGFloat)scaleForLevel:(float)level {
    CGFloat collapsed = _hasBarGeometry ? _collapsedScale : 1.0;
    return collapsed + (1.0 - collapsed) * (CGFloat)VibeEqualizerClampedLevel(level);
}

- (CGFloat)presentationScaleForBar:(CALayer *)bar {
    CALayer *presentation = (CALayer *)bar.presentationLayer;
    CGFloat scale = (presentation ?: bar).transform.m22;
    if (!isfinite(scale) || scale <= 0) {
        scale = bar.transform.m22;
    }
    return isfinite(scale) && scale > 0 ? scale : 1.0;
}

- (void)animateReleaseToDots {
    CGFloat collapsedScale = [self scaleForLevel:0];
    CGFloat presentationScales[kBarCount];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        presentationScales[i] = [self presentationScaleForBar:_bars[i]];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        [bar removeAnimationForKey:kLevelScaleAnimationKey];
        if (_lastAppliedScales[i] != collapsedScale) {
            bar.transform = CATransform3DMakeScale(1, collapsedScale, 1);
            _lastAppliedScales[i] = collapsedScale;
            VibeEqualizerDebugIncrement(&sTotalTransformWrites);
        }
        if (fabs(presentationScales[i] - collapsedScale) <= 1e-6) {
            continue;
        }
        CABasicAnimation *animation =
                [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        animation.fromValue = @(presentationScales[i]);
        animation.toValue = @(collapsedScale);
        animation.duration = kEqualizerReleaseAnimationSeconds;
        animation.timingFunction = VibeEqualizerEaseOutTimingFunction();
        [bar addAnimation:animation forKey:kLevelScaleAnimationKey];
    }
    [CATransaction commit];
}

- (void)retargetToLevels:(const float *)levels {
    BOOL changed[kBarCount] = {NO};
    float targets[kBarCount] = {0};
    BOOL hasChange = NO;
    for (NSUInteger i = 0; i < kBarCount; i++) {
        targets[i] = VibeEqualizerClampedLevel(levels[i]);
        changed[i] = VibeEqualizerTargetMateriallyChanged(_targetLevels[i], targets[i]);
        hasChange = hasChange || changed[i];
    }
    if (!hasChange) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        if (!changed[i]) {
            continue;
        }
        CALayer *bar = _bars[i];
        CGFloat presentationScale = [self presentationScaleForBar:bar];
        _targetLevels[i] = targets[i];
        CGFloat targetScale = [self scaleForLevel:targets[i]];
        bar.transform = CATransform3DMakeScale(1, targetScale, 1);
        _lastAppliedScales[i] = targetScale;
        VibeEqualizerDebugIncrement(&sTotalTransformWrites);

        CABasicAnimation *animation =
                [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        animation.fromValue = @(presentationScale);
        animation.toValue = @(targetScale);
        animation.duration = VibeEqualizerAnimationDuration(presentationScale, targetScale);
        animation.timingFunction = VibeEqualizerEaseOutTimingFunction();
        [bar addAnimation:animation forKey:kLevelScaleAnimationKey];
    }
    [CATransaction commit];
}

- (void)levelTick:(CADisplayLink *)link {
    VibeEqualizerDebugIncrement(&sTotalDisplayTicks);
    CFTimeInterval now = link.timestamp;

    id<EqualizerLevelSource> source = _levelSource;
    if (!source) {
        [self refreshActivity];
        return;
    }

    float newLevels[kBarCount];
    uint64_t newSequence = 0;
    BOOL copied = [source copyEqualizerLevels:newLevels count:kBarCount sequence:&newSequence];
    if (copied && newSequence != _lastSnapshotSequence) {
        NSAssert(newSequence != 0, @"Equalizer snapshot sequences must be nonzero");
        if (newSequence != 0) {
            [self retargetToLevels:newLevels];
            _lastSnapshotSequence = newSequence;
            _lastSnapshotTimestamp = now;
        }
    }
    if (_lastSnapshotTimestamp <= 0
            || now - _lastSnapshotTimestamp > kLevelSnapshotStaleSeconds) {
        const float settled[kBarCount] = {0};
        [self retargetToLevels:settled];
    }
}

// Geometry and invisible-state reconciliation are immediate. Any explicit
// animation was based on stale geometry or ownership, so it cannot survive a
// resize, visibility loss, detachment or source replacement.
- (void)applyBarScales {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        [bar removeAnimationForKey:kLevelScaleAnimationKey];
        CGFloat level = _levelLink ? _targetLevels[i] : 0.0f;
        CGFloat scale = [self scaleForLevel:level];
        if (_lastAppliedScales[i] == scale) {
            continue;
        }
        bar.transform = CATransform3DMakeScale(1, scale, 1);
        _lastAppliedScales[i] = scale;
        VibeEqualizerDebugIncrement(&sTotalTransformWrites);
    }
    [CATransaction commit];
}

#if DEBUG
+ (uint64_t)vibeDebugActiveDisplayLinkCount {
    return atomic_load_explicit(&sActiveDisplayLinks, memory_order_relaxed);
}

+ (uint64_t)vibeDebugTotalDisplayTickCount {
    return atomic_load_explicit(&sTotalDisplayTicks, memory_order_relaxed);
}

+ (uint64_t)vibeDebugTotalGeometryLayoutCount {
    return atomic_load_explicit(&sTotalGeometryLayouts, memory_order_relaxed);
}

+ (uint64_t)vibeDebugTotalTransformWriteCount {
    return atomic_load_explicit(&sTotalTransformWrites, memory_order_relaxed);
}
#endif

- (void)dealloc {
    for (CALayer *bar in _bars) {
        [bar removeAnimationForKey:kLevelScaleAnimationKey];
    }
    if (_levelLink) {
        [_levelLink invalidate];
        VibeEqualizerDebugDisplayLinkStopped();
    }
    if (_hasDeclaredLevels) {
        [_levelsDeclaredTo equalizerLevelsWanted:NO];
    }
}

@end
