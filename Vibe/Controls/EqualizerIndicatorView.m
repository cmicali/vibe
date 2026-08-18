//
//  EqualizerIndicatorView.m
//  Vibe
//
//  See the header for why this is shared. The tables and the math below are
//  the indicator; the #if blocks are only the platform's names for "lay out",
//  "the appearance changed", "I moved to a window" and "alpha".
//

#import "EqualizerIndicatorView.h"

#import "AudioLevelMath.h"   // the envelope only: header-only, no Audio/ code
#import "VibeWeakProxy.h"

#if TARGET_OS_OSX
#import "NSView+DarkMode.h"
#else
#import "UIView+DarkMode.h"
#endif

// An enum rather than a static const, because a const variable is not a C
// constant expression, so using it as an array size would make the tables
// below variable-length arrays.
enum { kBarCount = 5 };
static const CGFloat kBarGap = 1.5;

// Per-bar loops with distinct durations, so that the combined pattern does not
// visibly repeat. Each sequence ends where it starts, for a seamless cycle, and
// each bar moves independently around its envelope height.
static NSArray<NSNumber *> *barValues(NSUInteger bar) {
    switch (bar) {
        case 0:  return @[@0.4, @0.75, @0.3, @0.6, @0.35, @0.85, @0.4];
        case 1:  return @[@0.7, @0.35, @0.9, @0.5, @1.0, @0.45, @0.7];
        case 2:  return @[@1.0, @0.55, @0.85, @0.4, @0.95, @0.65, @1.0];
        case 3:  return @[@0.7, @1.0, @0.4, @0.8, @0.3, @0.9, @0.7];
        default: return @[@0.4, @0.8, @0.35, @0.65, @0.9, @0.3, @0.4];
    }
}
static const CFTimeInterval kBarDurations[kBarCount] = {0.9, 1.15, 1.0, 1.25, 0.95};

// The bars ARE the bands: one each, and the reactive path would have nothing to
// map if they ever diverged.
_Static_assert(kBarCount == kLevelBandCount, "one bar per band");

// A frame this long is a stall — a scroll hitch, a resumed app — and easing
// across it would land the bars somewhere arbitrary. Clamped, they simply
// continue from where they were.
static const CFTimeInterval kMaxLevelFrameSeconds = 0.1;

@implementation EqualizerIndicatorView {
    NSArray<CALayer *> *_bars;
    // The paused pose, recomputed on every layout: the scale at which a bar is
    // as tall as it is wide. It is the floor the reactive path grows from, so
    // level 0 and "not playing" draw the identical row of dots.
    CGFloat             _collapsedScale;
    CADisplayLink      *_levelLink;
    float               _envelope[kBarCount];
    CFTimeInterval      _lastLevelTimestamp;
    // The source we currently hold demand against, or nil. Held rather than a
    // BOOL so a levelSource swap under a running link releases the OLD source
    // instead of leaving it producing for nobody.
    __weak id<EqualizerLevelSource> _levelsDeclaredTo;
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
            [self.layer addSublayer:bar];
            [bars addObject:bar];
        }
        _bars = bars;
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *bar in _bars) {
        bar.backgroundColor = color;
    }
    [CATransaction commit];
}

#if TARGET_OS_OSX
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyAppearanceColor];
}
#endif

// The paused pose: every bar collapsed to its own width, which with the pill
// corner radius makes it a circle — a row of dots. It is also the model value
// the keyframes animate around, so removing the animation settles here.
//
// Scaled from the bar width rather than a constant, because "as short as it
// goes" is a shape, not a number: the same view drawn at any size collapses to
// round dots instead of to stadiums or slivers.
- (CGFloat)collapsedScaleForBarWidth:(CGFloat)barWidth height:(CGFloat)height {
    return height > 0 ? MIN(1.0, barWidth / height) : 1.0;
}

- (void)layoutBars {
    CGFloat barWidth = (self.bounds.size.width - kBarGap * (kBarCount - 1)) / (CGFloat)kBarCount;
    CGFloat height = self.bounds.size.height;
    CGFloat collapsed = [self collapsedScaleForBarWidth:barWidth height:height];
    _collapsedScale = collapsed;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        bar.bounds = CGRectMake(0, 0, barWidth, height);
        bar.position = CGPointMake(i * (barWidth + kBarGap) + barWidth / 2, height / 2);
        bar.cornerRadius = barWidth / 2; // pill ends, like the icon's bars
    }
    [CATransaction commit];
    // TRAP: settle the CURRENT pose, never a hardcoded collapsed one. An iOS
    // table cell lays out on every displayed frame, so a collapsed write here
    // lands after the display link's and the bars never leave the dots.
    // applyBarScales resolves to exactly collapsed while no link is running,
    // which is the model value the keyframes animate around.
    [self applyBarScales];
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
    // A relayout re-seats the model transform the keyframes animate around,
    // which drops the running animation's effect; reinstall it. On the mac the
    // row is laid out once, but an iOS cell is laid out on every reuse.
    [self updateAnimations];
}
#endif

- (void)setAnimating:(BOOL)animating {
    _animating = animating;
    // Only a light dim when paused: the collapse to dots is what says "not
    // playing" now, and dimming a row of dots as hard as it dimmed full-height
    // bars left almost nothing to see.
#if TARGET_OS_OSX
    self.alphaValue = animating ? 1.0 : 0.8;
#else
    self.alpha = animating ? 1.0 : 0.8;
#endif
    [self updateAnimations];
}

// Core Animation strips animations whenever the layer leaves the layer tree,
// and cell reuse detaches the view, so reinstall them on re-attach. The color
// is re-resolved too, because attaching to a window can change the effective
// appearance without an appearance callback.
- (void)didMoveToWindowShared {
    [self applyAppearanceColor];
    [self updateAnimations];
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
    _levelSource = levelSource;
    [self updateAnimations];
}

- (void)updateAnimations {
    BOOL run = _animating && self.window != nil;
    // With a source the bars follow the audio; without one they run the canned
    // keyframes, which is every macOS row and any iOS row before the model is
    // handed over.
    //
    // Demand is reconciled here rather than in startLevelLink, which early-
    // returns on an already-running link and so would miss a source swap.
    [self declareLevelsWanted:(run && _levelSource != nil)];
    if (run && _levelSource) {
        [self startLevelLink];
        return;
    }
    [self stopLevelLink];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        if (!run) {
            [bar removeAnimationForKey:@"eq"];
            continue;
        }
        if ([bar animationForKey:@"eq"]) {
            continue;
        }
        CAKeyframeAnimation *bounce = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
        bounce.values = barValues(i);
        bounce.duration = kBarDurations[i];
        bounce.repeatCount = HUGE_VALF;
        [bar addAnimation:bounce forKey:@"eq"];
    }
}

#pragma mark - Reactive bars

// Balances itself: a source is told YES once and NO once, and a swap tells the
// outgoing one NO before the incoming one YES, so a counting source stays exact.
- (void)declareLevelsWanted:(BOOL)wanted {
    id<EqualizerLevelSource> target = wanted ? _levelSource : nil;
    if (target == _levelsDeclaredTo) {
        return;
    }
    [_levelsDeclaredTo equalizerLevelsWanted:NO];
    _levelsDeclaredTo = target;
    [target equalizerLevelsWanted:YES];
}

- (void)startLevelLink {
    if (_levelLink) {
        return;
    }
    // TRAP: the two modes drive the same property. A keyframe animation left
    // running would composite over every per-frame write, and the bars would
    // read as the canned loop with a wobble rather than as the audio.
    for (CALayer *bar in _bars) {
        [bar removeAnimationForKey:@"eq"];
    }
    _lastLevelTimestamp = 0;
    // Through a weak proxy, because the link retains its target and a table
    // cell's indicator must still reach dealloc. 30-60 is the same band the
    // card's playhead link asks for: the envelope is time-based, so a dropped
    // frame costs smoothness and never position.
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
    _levelLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_levelLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopLevelLink {
    if (!_levelLink) {
        return;
    }
    [_levelLink invalidate];
    _levelLink = nil;
    for (NSUInteger i = 0; i < kBarCount; i++) {
        _envelope[i] = 0;
    }
    // The reactive path writes the model transform directly, so unlike the
    // keyframe path there is no animation to remove that would restore the
    // paused pose. Settle it by hand.
    [self applyBarScales];
}

- (void)levelTick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = _lastLevelTimestamp > 0 ? now - _lastLevelTimestamp : link.duration;
    _lastLevelTimestamp = now;
    if (dt <= 0 || dt > kMaxLevelFrameSeconds) {
        dt = MIN(link.duration > 0 ? link.duration : 1.0 / 60.0, kMaxLevelFrameSeconds);
    }

    float levels[kBarCount] = {0};
    // No levels is not silence: the engine's deferred idle stop takes the tap
    // a few seconds after a pause, and the bars should fall rather than freeze
    // where they were.
    BOOL published = [_levelSource copyEqualizerLevels:levels count:kBarCount];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        float target = published ? levels[i] : 0.0f;
        _envelope[i] = VibeLevelEnvelope(_envelope[i], target, (float)dt,
                                         kLevelAttackSeconds, kLevelReleaseSeconds);
    }
    [self applyBarScales];
}

// Level 0 is the paused pose and level 1 is full height, so a bar can never
// draw shorter than the dot it collapses to.
- (void)applyBarScales {
    CGFloat collapsed = _collapsedScale > 0 ? _collapsedScale : 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CGFloat level = _levelLink ? (CGFloat)_envelope[i] : 0.0;
        CGFloat scale = collapsed + (1.0 - collapsed) * level;
        _bars[i].transform = CATransform3DMakeScale(1, scale, 1);
    }
    [CATransaction commit];
}

- (void)dealloc {
    [_levelLink invalidate];
    // The last NO. A cell's indicator is deallocated without ever leaving a
    // window on a playlist replace, so this is not merely belt and braces.
    [_levelsDeclaredTo equalizerLevelsWanted:NO];
}

@end
