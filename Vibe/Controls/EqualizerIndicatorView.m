//
//  EqualizerIndicatorView.m
//  Vibe
//

#import "EqualizerIndicatorView.h"

// enum, not static const: a const variable isn't a C constant expression,
// so using it as an array size would make the tables below VLAs.
enum { kBarCount = 3 };
static const CGFloat kBarGap = 2;

// Pose shown while paused; also the model value the animation returns to
// when it is removed (the keyframes animate transform.scale.y around it).
static const CGFloat kPausedHeights[kBarCount] = {0.5, 0.85, 0.65};

// Per-bar loops with distinct durations so the combined pattern doesn't
// visibly repeat. Each sequence ends where it starts for a seamless cycle.
static NSArray<NSNumber *> *barValues(NSUInteger bar) {
    switch (bar) {
        case 0:  return @[@0.5, @0.95, @0.35, @0.75, @0.55, @1.0, @0.5];
        case 1:  return @[@0.85, @0.4, @1.0, @0.6, @0.9, @0.3, @0.85];
        default: return @[@0.65, @1.0, @0.5, @0.85, @0.3, @0.9, @0.65];
    }
}
static const CFTimeInterval kBarDurations[kBarCount] = {0.9, 1.15, 1.0};

@implementation EqualizerIndicatorView {
    NSArray<CALayer *> *_bars;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _color = NSColor.whiteColor;
        NSMutableArray<CALayer *> *bars = [NSMutableArray arrayWithCapacity:kBarCount];
        for (NSUInteger i = 0; i < kBarCount; i++) {
            CALayer *bar = [CALayer layer];
            bar.anchorPoint = CGPointMake(0.5, 0); // grow from the baseline
            bar.backgroundColor = _color.CGColor;
            [self.layer addSublayer:bar];
            [bars addObject:bar];
        }
        _bars = bars;
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat barWidth = (self.bounds.size.width - kBarGap * (kBarCount - 1)) / (CGFloat)kBarCount;
    CGFloat height = self.bounds.size.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < kBarCount; i++) {
        CALayer *bar = _bars[i];
        bar.bounds = CGRectMake(0, 0, barWidth, height);
        bar.position = CGPointMake(i * (barWidth + kBarGap) + barWidth / 2, 0);
        bar.transform = CATransform3DMakeScale(1, kPausedHeights[i], 1);
    }
    [CATransaction commit];
}

- (void)setColor:(NSColor *)color {
    _color = color;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *bar in _bars) {
        bar.backgroundColor = color.CGColor;
    }
    [CATransaction commit];
}

- (void)setAnimating:(BOOL)animating {
    _animating = animating;
    [self updateAnimations];
}

// Core Animation strips animations whenever the layer leaves the layer tree
// (table cell reuse detaches the view); reinstall on re-attach.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateAnimations];
}

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
