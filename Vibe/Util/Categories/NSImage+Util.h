//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSImage (Util)

// Redraws the image at newSize into an sRGB bitmap. Returns nil if the
// bitmap or its drawing context can't be created — never falls back to the
// full-size original (callers resize precisely to shed its memory).
- (nullable NSImage *)resizedImage:(NSSize)newSize;

// The image's dominant color, for tinting a backdrop to match album art:
// the saturation×brightness-weighted average of the most-populated hue band,
// so a colorful accent wins over a large muted background. Falls back to the
// plain average for effectively monochrome images (returns their gray).
// Downsamples internally — cost is independent of image size. Returns nil
// only if the image can't be rasterized.
- (nullable NSColor *)dominantColor;
@end
