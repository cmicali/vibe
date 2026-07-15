//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSImage+Util.h"

@implementation NSImage (Util)

- (NSImage *)resizedImage:(NSSize)newSize
{
    // A zero dimension produces a nil bitmap rep, which crashes downstream.
    newSize.width = MAX(1.0, newSize.width);
    newSize.height = MAX(1.0, newSize.height);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                                               initWithBitmapDataPlanes:NULL
                                                             pixelsWide:newSize.width
                                                             pixelsHigh:newSize.height
                                                          bitsPerSample:8
                                                        samplesPerPixel:4
                                                               hasAlpha:YES
                                                               isPlanar:NO
                                                         colorSpaceName:NSCalibratedRGBColorSpace
                                                            bytesPerRow:0
                                                           bitsPerPixel:0];
    // Retag (no pixel conversion — the buffer is still empty) so the draw
    // below color-matches into sRGB. Leaving the rep calibrated ("generic"
    // RGB) shifts gamma/saturation for sRGB and P3 sources.
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rep) {
        return nil;
    }
    rep.size = newSize;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!context) {
        return nil;
    }
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [self drawInRect:NSMakeRect(0, 0, newSize.width, newSize.height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    NSImage *newImage = [[NSImage alloc] initWithSize:newSize];
    [newImage addRepresentation:rep];
    return newImage;
}

@end
