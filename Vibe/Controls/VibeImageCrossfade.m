//
// Created by Christopher Micali on 7/8/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// See VibeImageCrossfade.h for why this is a snapshot overlay rather than a
// CATransition or a view snapshot.

#import "VibeImageCrossfade.h"
#import <QuartzCore/QuartzCore.h>

const NSTimeInterval kVibeArtCrossfadeDuration = 0.1;

NSString *const kVibeCrossfadeOverlayName = @"VibeCrossfadeOverlay";

// Match the overlay's scaling behavior to the image view's own.
static CALayerContentsGravity VibeGravityForImageScaling(NSImageScaling scaling) {
    switch (scaling) {
        case NSImageScaleAxesIndependently: return kCAGravityResize;
        case NSImageScaleNone:              return kCAGravityCenter;
        default:                            return kCAGravityResizeAspect;
    }
}

void VibeBeginImageCrossfade(NSImageView *view) {
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
