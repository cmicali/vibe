//
//  EqualizerIndicatorView.m
//  Vibe
//

#import "EqualizerIndicatorView.h"
#import "NSView+DarkMode.h"

// enum, not static const: a const variable isn't a C constant expression,
// so using it as an array size would make the tables below VLAs.
enum { kBarCount = 5 };
static const CGFloat kBarGap = 1.5;

// Pose shown while paused — the diamond envelope of the app icon's waveform
// (short, tall, tallest, tall, short); also the model value the animation
// returns to when it is removed (the keyframes animate transform.scale.y
// around it).
static const CGFloat kPausedHeights[kBarCount] = {0.4, 0.7, 1.0, 0.7, 0.4};

// Per-bar loops with distinct durations so the combined pattern doesn't
// visibly repeat. Each sequence ends where it starts for a seamless cycle,
// and each bar moves independently around its envelope height.
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

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        NSMutableArray<CALayer *> *bars = [NSMutableArray arrayWithCapacity:kBarCount];
        for (NSUInteger i = 0; i < kBarCount; i++) {
            CALayer *bar = [CALayer layer];
            // Centered anchor: bars grow and shrink symmetrically around the
            // vertical midline, like the app icon's waveform.
            bar.anchorPoint = CGPointMake(0.5, 0.5);
            [self.layer addSublayer:bar];
            [bars addObject:bar];
        }
        _bars = bars;
        [self applyAppearanceColor];
    }
    return self;
}

- (void)applyAppearanceColor {
    CGColorRef color = (self.isDark ? NSColor.whiteColor : NSColor.blackColor).CGColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *bar in _bars) {
        bar.backgroundColor = color;
    }
    [CATransaction commit];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyAppearanceColor];
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
        bar.position = CGPointMake(i * (barWidth + kBarGap) + barWidth / 2, height / 2);
        bar.cornerRadius = barWidth / 2; // pill ends, like the icon's bars
        bar.transform = CATransform3DMakeScale(1, kPausedHeights[i], 1);
    }
    [CATransaction commit];
}

- (void)setAnimating:(BOOL)animating {
    _animating = animating;
    // Full strength while playing; dimmed to half when the current track is
    // paused so the indicator reads as "stopped".
    self.alphaValue = animating ? 1.0 : 0.5;
    [self updateAnimations];
}

// Core Animation strips animations whenever the layer leaves the layer tree
// (table cell reuse detaches the view); reinstall on re-attach. The color is
// re-resolved too: attaching to a window can change the effective appearance
// without a viewDidChangeEffectiveAppearance callback.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self applyAppearanceColor];
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
