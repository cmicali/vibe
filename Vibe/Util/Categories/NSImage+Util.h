//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSImage (Util)

// Runs draw inside a fresh explicit-sRGB RGBA8 bitmap context of `size`
// pixels (one point per pixel) and returns the image wrapping that bitmap,
// or nil when the rep or context cannot be built. This — not lockFocus,
// which is soft-deprecated and whose backing rep picks up the deepest
// screen's scale, and not imageWithSize:flipped:drawingHandler:, whose
// deferred handler re-renders per destination and yields no readable bitmap
// — is the one home of the rep-retagging ballet shared by resizedImage:,
// the dock icon, and the drag label.
+ (nullable NSImage *)imageWithSize:(NSSize)size drawnBy:(void (NS_NOESCAPE ^ _Nonnull)(void))draw;

// Redraws the image at newSize into an sRGB bitmap. It returns nil if the
// bitmap or its drawing context cannot be created, and never falls back to the
// full-size original, because callers resize precisely to shed its memory.
- (nullable NSImage *)resizedImage:(NSSize)newSize;

// The image's dominant color, for tinting a backdrop to match album art. It is
// the average of the most-populated hue band, weighted by saturation times
// brightness, so that a colorful accent beats a large muted background. For an
// effectively monochrome image it falls back to the plain average and returns
// that gray. It downsamples internally, so its cost is independent of image
// size, and it returns nil only if the image cannot be rasterized.
- (nullable NSColor *)dominantColor;
@end
