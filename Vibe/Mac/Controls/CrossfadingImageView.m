//
// Created by Christopher Micali on 7/18/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "CrossfadingImageView.h"
#import <QuartzCore/QuartzCore.h>

const NSTimeInterval kVibeArtCrossfadeDuration = 0.1;

static NSString *const kVibeCrossfadeOverlayName = @"VibeCrossfadeOverlay";

// Match the overlay's scaling behavior to the image view's own. Sizes matter
// under NSImageScaleProportionallyDown, NSImageView's default: "down" never
// upscales, but kCAGravityResizeAspect does, so a small image would visibly
// jump between its natural size and the fitted size during the fade.
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

// The overlay cross-fade. Called before [super setImage:], it overlays the
// outgoing image and fades it out over the incoming one. It no-ops when the
// view is not yet on screen, or has nothing to fade from.
//
// Why not a CATransition on the backing layer? NSImageView redraws into its
// layer on AppKit's own display schedule, so a transition added at setImage:
// time is not reliably in the same CA transaction as the contents change, and
// silently no-ops. Why not a view snapshot, through cacheDisplayInRect:?
// NSImageView draws through updateLayer, so the drawRect-based snapshot comes
// back blank and the fade is invisible. Instead the overlay is built directly
// from the outgoing NSImage itself, stacked on top while the new image renders
// beneath, and faded out explicitly. Nothing here depends on AppKit's drawing
// path or transaction timing.
static void BeginImageCrossfade(NSImageView *view) {
    NSImage *oldImage = view.image;
    if (!view.window || !view.layer || !oldImage || NSIsEmptyRect(view.bounds)) {
        return;
    }
    CGImageRef cg = [oldImage CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) {
        return;
    }
    // A fade may already be in flight from a rapid previous change, so replace
    // it.
    for (CALayer *sublayer in [view.layer.sublayers copy]) {
        if ([sublayer.name isEqualToString:kVibeCrossfadeOverlayName]) {
            [sublayer removeFromSuperlayer];
        }
    }
    CALayer *overlay = [CALayer layer];
    overlay.name = kVibeCrossfadeOverlayName;
    overlay.frame = view.layer.bounds;
    overlay.contentsScale = view.window.backingScaleFactor ?: 2.0;
    overlay.contents = (__bridge id)cg;
    overlay.contentsGravity = GravityForImageScaling(view.imageScaling, oldImage.size, view.bounds.size);
    overlay.masksToBounds = YES;
    // NSImageView renders its image through internal machinery that may add
    // sublayers of its own, so keep the overlay above everything in this view.
    overlay.zPosition = 10000;
    [view.layer addSublayer:overlay];

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [overlay removeFromSuperlayer];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.0;
    fade.duration = kVibeArtCrossfadeDuration;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    // Hold the faded-out state until the completion block removes the layer,
    // so that it cannot pop back to full opacity for a frame.
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
    // Layer-backed, so that setImage: can cross-fade through the snapshot
    // overlay.
    self.wantsLayer = YES;
}

// Cross-fades between images rather than swapping instantly. Living in
// setImage: covers every path the image can arrive by, async renders included.
// See BeginImageCrossfade above.
- (void)setImage:(NSImage *)image {
    if (image != self.image) {
        BeginImageCrossfade(self);
    }
    [super setImage:image];
}

@end
