//
//  EqualizerIndicatorView.m
//  Vibe
//
//  See the header for why this is shared. The tables and the math below are
//  the indicator; the #if blocks are only the platform's names for "lay out",
//  "the appearance changed", "I moved to a window" and "alpha".
//

#import "EqualizerIndicatorView.h"

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

@implementation EqualizerIndicatorView {
    NSArray<CALayer *> *_bars;
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        bar.bounds = CGRectMake(0, 0, barWidth, height);
        bar.position = CGPointMake(i * (barWidth + kBarGap) + barWidth / 2, height / 2);
        bar.cornerRadius = barWidth / 2; // pill ends, like the icon's bars
        bar.transform = CATransform3DMakeScale(1, collapsed, 1);
    }
    [CATransaction commit];
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

- (void)updateAnimations {
    BOOL run = _animating && self.window != nil;
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

@end
