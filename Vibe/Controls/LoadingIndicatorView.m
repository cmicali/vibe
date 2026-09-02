//
//  LoadingIndicatorView.m
//  Vibe
//
//  See the header for why this is shared. The #if blocks are only the
//  platform's names for "lay out", "the appearance changed" and "the backing
//  scale changed".
//

#import "LoadingIndicatorView.h"

#import "LoadingIndicator.h"

#if TARGET_OS_OSX
#import "NSView+DarkMode.h"
#else
#import "UIView+DarkMode.h"
#endif

@implementation LoadingIndicatorView {
    LoadingIndicator *_indicator;   // nil unless active
    CGRect            _laidOutBounds;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
#if TARGET_OS_OSX
        self.wantsLayer = YES;
#else
        // The iOS twin of viewDidChangeEffectiveAppearance.
        __weak LoadingIndicatorView *weakSelf = self;
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class]
                          withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [weakSelf applyAppearance];
        }];
#endif
        _progress = -1;
    }
    return self;
}

- (CGFloat)currentContentsScale {
#if TARGET_OS_OSX
    return self.window ? self.window.backingScaleFactor : 2;
#else
    // displayScale is 0 until the view joins a hierarchy; the window scene's
    // screen is the next-best context. 2 matches the mac fallback above —
    // every current device is at least 2x, and a wrong guess here only lasts
    // until didMoveToWindow redraws. UIScreen.mainScreen is deprecated on
    // iOS 26 and wrong on iPad multi-window anyway.
    CGFloat scale = self.traitCollection.displayScale;
    if (scale > 0) {
        return scale;
    }
    scale = self.window.windowScene.screen.scale;
    return scale > 0 ? scale : 2;
#endif
}

- (void)setActive:(BOOL)active {
    if (_active == active) {
        return;
    }
    _active = active;
    if (active) {
        _indicator = [[LoadingIndicator alloc]
                initInLayer:self.layer
                      style:VibeLoadingIndicatorStyleRow
                     isDark:self.isDark
              contentsScale:[self currentContentsScale]];
        _indicator.colorOverride = _barColor;
        _laidOutBounds = CGRectNull;
        [self forwardLayout];
        if (_progress >= 0) {
            [_indicator setProgress:_progress inBounds:self.bounds];
        }
    }
    else {
        // Never endSweepKeepingFill — that exists for the waveform's "data
        // landed while the download continues" case, which has no row
        // equivalent.
        [_indicator removeFromHost];
        _indicator = nil;
        _progress = -1;
    }
}

- (void)setProgress:(float)progress {
    _progress = progress;
    [_indicator setProgress:progress inBounds:self.bounds];
}

- (void)setBarColor:(VibeColor *)barColor {
    _barColor = barColor;
    _indicator.colorOverride = barColor;
}

- (void)forwardLayout {
    if (!_indicator) {
        return;
    }
    CGRect bounds = self.bounds;
    if (CGRectEqualToRect(bounds, _laidOutBounds)) {
        return;
    }
    _laidOutBounds = bounds;
    [_indicator layoutInBounds:bounds];
}

- (void)applyAppearance {
    [_indicator updateColorsForDark:self.isDark];
}

#if TARGET_OS_OSX

- (void)layout {
    [super layout];
    [self forwardLayout];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyAppearance];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [_indicator updateContentsScale:[self currentContentsScale]];
}

// Scroll-out and detachment: a row leaving its window must not keep a live
// animation, and its table re-configures it on the way back in.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        self.active = NO;
    }
}

#else

- (void)layoutSubviews {
    [super layoutSubviews];
    [self forwardLayout];
}

// The iOS twin of viewDidMoveToWindow.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        self.active = NO;
    }
}

#endif

@end
