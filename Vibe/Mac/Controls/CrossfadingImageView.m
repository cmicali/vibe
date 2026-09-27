//
//  CrossfadingImageView.m
//  Vibe
//

#import "CrossfadingImageView.h"
#import <QuartzCore/QuartzCore.h>

const NSTimeInterval kVibeArtCrossfadeDuration = 0.1;

static NSString *const kVibeCrossfadeOverlayName = @"VibeCrossfadeOverlay";

// Matches the view's own scaling: under NSImageScaleProportionallyDown, the
// default, a small image would otherwise jump size during the fade.
static CALayerContentsGravity GravityForImageScaling(NSImageScaling scaling,
                                                     NSSize imageSize,
                                                     NSSize boundsSize) {
    switch (scaling) {
        case NSImageScaleAxesIndependently: return kCAGravityResize;
        case NSImageScaleNone:              return kCAGravityCenter;
        case NSImageScaleProportionallyDown:
            // It already fits, so it is drawn at natural size, like the view.
            if (imageSize.width <= boundsSize.width && imageSize.height <= boundsSize.height) {
                return kCAGravityCenter;
            }
            return kCAGravityResizeAspect;
        case NSImageScaleProportionallyUpOrDown:
            return kCAGravityResizeAspect;
    }
    return kCAGravityResizeAspect;
}

// Before [super setImage:]: overlays the outgoing image and fades it out. Not
// a CATransition: NSImageView redraws on AppKit's schedule, so the transition
// misses the contents change. Not cacheDisplayInRect:: NSImageView draws
// through updateLayer, so that snapshot is blank.
static void BeginImageCrossfade(NSImageView *view) {
    NSImage *oldImage = view.image;
    if (!view.window || !view.layer || !oldImage || NSIsEmptyRect(view.bounds)) {
        return;
    }
    CGImageRef cg = [oldImage CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) {
        return;
    }
    // In-flight fades keep running, so a burst blends continuously; this
    // overlay slides in BENEATH the older ones, which left the screen first.
    // Capped at two: the oldest, the most faded, goes at once.
    NSMutableArray<CALayer *> *inFlight = [NSMutableArray array];
    for (CALayer *sublayer in view.layer.sublayers) {
        if ([sublayer.name isEqualToString:kVibeCrossfadeOverlayName]) {
            [inFlight addObject:sublayer];
        }
    }
    while (inFlight.count >= 2) {
        // Sublayer order is back-to-front, so the last is the oldest.
        [inFlight.lastObject removeFromSuperlayer];
        [inFlight removeLastObject];
    }
    CALayer *overlay = [CALayer layer];
    overlay.name = kVibeCrossfadeOverlayName;
    overlay.frame = view.layer.bounds;
    overlay.contentsScale = view.window.backingScaleFactor ?: 2.0;
    overlay.contents = (__bridge id)cg;
    overlay.contentsGravity = GravityForImageScaling(view.imageScaling, oldImage.size, view.bounds.size);
    overlay.masksToBounds = YES;
    // Above any sublayers NSImageView adds itself.
    overlay.zPosition = 10000;
    if (inFlight.count > 0) {
        [view.layer insertSublayer:overlay below:inFlight.firstObject];
    }
    else {
        [view.layer addSublayer:overlay];
    }

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [overlay removeFromSuperlayer];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.0;
    fade.duration = kVibeArtCrossfadeDuration;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    // Or it pops back to full opacity for a frame before removal.
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [overlay addAnimation:fade forKey:@"fade"];
    [CATransaction commit];
}

@implementation CrossfadingImageView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    [self unregisterDraggedTypes];
    self.wantsLayer = YES; // for the cross-fade overlay
}

// In setImage:, so every path an image arrives by fades.
- (void)setImage:(NSImage *)image {
    if (image != self.image) {
        BeginImageCrossfade(self);
    }
    [super setImage:image];
}

@end
