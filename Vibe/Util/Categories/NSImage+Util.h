//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSImage (Util)

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
