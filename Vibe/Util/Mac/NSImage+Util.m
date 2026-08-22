//
//  NSImage+Util.m
//  Vibe
//

#import "NSImage+Util.h"
#import "PlatformImage.h"


@implementation NSImage (Util)

+ (NSImage *)imageWithSize:(NSSize)size drawnBy:(void (NS_NOESCAPE ^)(void))draw {
    // A zero dimension produces a nil bitmap rep, which crashes downstream.
    size.width = MAX(1.0, size.width);
    size.height = MAX(1.0, size.height);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                                               initWithBitmapDataPlanes:NULL
                                                             pixelsWide:(NSInteger)size.width
                                                             pixelsHigh:(NSInteger)size.height
                                                          bitsPerSample:8
                                                        samplesPerPixel:4
                                                               hasAlpha:YES
                                                               isPlanar:NO
                                                         colorSpaceName:NSCalibratedRGBColorSpace
                                                            bytesPerRow:0
                                                           bitsPerPixel:0];
    // Retag the rep, with no pixel conversion, since the buffer is still
    // empty, so that the draw below color-matches into sRGB. Leaving the rep
    // calibrated, as generic RGB, shifts the gamma and saturation of sRGB and
    // P3 sources.
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rep) {
        return nil;
    }
    rep.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!context) {
        return nil;
    }
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image addRepresentation:rep];
    return image;
}

- (NSImage *)resizedImage:(NSSize)newSize
{
    return [NSImage imageWithSize:newSize drawnBy:^{
        [self drawInRect:NSMakeRect(0, 0, MAX(1.0, newSize.width), MAX(1.0, newSize.height))
                fromRect:NSZeroRect
               operation:NSCompositingOperationCopy
                fraction:1.0];
    }];
}

- (NSImage *)squareCroppedImage {
    NSSize size = self.size;
    if (size.width <= 0 || size.height <= 0) {
        return nil;
    }
    CGFloat side = MIN(size.width, size.height);
    // Sub-point differences are invisible once drawn, and re-rendering a
    // square cover would cost a full bitmap for nothing.
    if (fabs(size.width - size.height) < 1.0) {
        return self;
    }
    NSRect crop = NSMakeRect((size.width - side) / 2, (size.height - side) / 2, side, side);
    return [NSImage imageWithSize:NSMakeSize(side, side) drawnBy:^{
        [self drawInRect:NSMakeRect(0, 0, side, side)
                fromRect:crop
               operation:NSCompositingOperationCopy
                fraction:1.0];
    }];
}

- (NSColor *)dominantColor {
    // The algorithm is shared with iOS — one hue histogram, in CoreGraphics
    // terms, so the two platforms cannot drift on what a cover's color is.
    return VibeDominantColorOfImage(self);
}

@end
