//
// Created by Christopher Micali on 7/8/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// Shared overlay cross-fade for the artwork image views.
//
// Why not a CATransition on the backing layer: NSImageView redraws into its
// layer on AppKit's own display schedule, so a transition added at setImage:
// time is not reliably in the same CA transaction as the contents change and
// silently no-ops. Why not a view snapshot (cacheDisplayInRect:): NSImageView
// draws via updateLayer, so the drawRect-based snapshot comes back BLANK and
// the fade is invisible. Instead the overlay is built directly from the
// outgoing NSImage itself, stacked on top while the new image renders
// beneath, and explicitly faded out — nothing here depends on AppKit's
// drawing path or transaction timing.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

static const NSTimeInterval kVibeArtCrossfadeDuration = 0.1;

static NSString *const kVibeCrossfadeOverlayName = @"VibeCrossfadeOverlay";

// Match the overlay's scaling behavior to the image view's own.
static inline CALayerContentsGravity VibeGravityForImageScaling(NSImageScaling scaling) {
    switch (scaling) {
        case NSImageScaleAxesIndependently: return kCAGravityResize;
        case NSImageScaleNone:              return kCAGravityCenter;
        default:                            return kCAGravityResizeAspect;
    }
}

// Call BEFORE [super setImage:]: overlays the outgoing image and fades it
// out over the incoming one. No-ops when the view isn't on screen yet or has
// nothing to fade from.
static inline void VibeBeginImageCrossfade(NSImageView *view) {
    NSImage *oldImage = view.image;
    if (!view.window || !view.layer || !oldImage || NSIsEmptyRect(view.bounds)) {
        return;
    }
    CGImageRef cg = [oldImage CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) {
        return;
    }
    // A fade may already be in flight from a rapid previous change; replace it.
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
    overlay.contentsGravity = VibeGravityForImageScaling(view.imageScaling);
    overlay.masksToBounds = YES;
    // NSImageView renders its image through internal machinery that may add
    // its own sublayers; keep the overlay above everything in this view.
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
    // so it can't pop back to full opacity for a frame.
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [overlay addAnimation:fade forKey:@"fade"];
    [CATransaction commit];
}
