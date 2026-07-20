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

- (NSColor *)dominantColor {
    static const NSInteger kSide = 32;     // 1024 samples is plenty for one color
    static const NSInteger kHueBins = 12;
    NSImage *small = [self resizedImage:NSMakeSize(kSide, kSide)];
    NSBitmapImageRep *rep = (NSBitmapImageRep *)small.representations.firstObject;
    if (![rep isKindOfClass:[NSBitmapImageRep class]]) {
        return nil;
    }
    // Direct buffer iteration: colorAtX:y: allocates an NSColor and runs
    // colorspace conversions per pixel — orders of magnitude more work than
    // reading the layout resizedImage always produces (meshed 8-bit RGBA,
    // alpha last). The guards make the layout assumption explicit rather
    // than trusted.
    unsigned char *data = rep.bitmapData;
    if (!data || rep.isPlanar || rep.bitsPerPixel != 32 || rep.samplesPerPixel != 4
            || (rep.bitmapFormat & (NSBitmapFormatAlphaFirst | NSBitmapFormatFloatingPointSamples))) {
        return nil;
    }
    BOOL premultiplied = !(rep.bitmapFormat & NSBitmapFormatAlphaNonpremultiplied);
    NSInteger bytesPerRow = rep.bytesPerRow;
    // Weighted hue histogram: vivid pixels (saturated AND not near-black)
    // vote for their hue band; grays and shadows abstain but still feed the
    // monochrome fallback average.
    double binWeight[kHueBins], binR[kHueBins], binG[kHueBins], binB[kHueBins];
    memset(binWeight, 0, sizeof(binWeight));
    memset(binR, 0, sizeof(binR));
    memset(binG, 0, sizeof(binG));
    memset(binB, 0, sizeof(binB));
    double avgR = 0, avgG = 0, avgB = 0;
    NSInteger avgCount = 0;
    for (NSInteger y = 0; y < kSide; y++) {
        const unsigned char *row = data + y * bytesPerRow;
        for (NSInteger x = 0; x < kSide; x++) {
            const unsigned char *px = row + x * 4;
            double a = px[3] / 255.0;
            if (a < 0.5) {
                continue;
            }
            double r = px[0] / 255.0, g = px[1] / 255.0, b = px[2] / 255.0;
            if (premultiplied) {
                r = MIN(1.0, r / a);
                g = MIN(1.0, g / a);
                b = MIN(1.0, b / a);
            }
            avgR += r; avgG += g; avgB += b;
            avgCount++;
            double maxc = MAX(r, MAX(g, b));
            double minc = MIN(r, MIN(g, b));
            double brightness = maxc;
            double saturation = maxc > 0 ? (maxc - minc) / maxc : 0;
            if (saturation < 0.15 || brightness < 0.1) {
                continue;
            }
            // saturation >= 0.15 guarantees maxc > minc, so delta > 0.
            double delta = maxc - minc;
            double hue;
            if (maxc == r)      hue = fmod((g - b) / delta + 6.0, 6.0) / 6.0;
            else if (maxc == g) hue = ((b - r) / delta + 2.0) / 6.0;
            else                hue = ((r - g) / delta + 4.0) / 6.0;
            double weight = saturation * brightness;
            // Hue wraps: red straddles the 0.0/1.0 seam, so round to the
            // nearest bin center and fold with a modulo — both edges land in
            // bin 0. Flooring instead split red's vote across the first and
            // last bins, uniquely penalizing red covers in the election.
            NSInteger bin = ((NSInteger)lround(hue * kHueBins)) % kHueBins;
            binWeight[bin] += weight;
            binR[bin] += r * weight;
            binG[bin] += g * weight;
            binB[bin] += b * weight;
        }
    }
    if (avgCount == 0) {
        return nil;
    }
    NSInteger best = 0;
    for (NSInteger i = 1; i < kHueBins; i++) {
        if (binWeight[i] > binWeight[best]) {
            best = i;
        }
    }
    // Under ~2% of pixels vivid: a monochrome cover — its overall gray is the
    // honest answer (a hue teased out of noise would tint it a random color).
    if (binWeight[best] < 0.02 * kSide * kSide) {
        return [NSColor colorWithSRGBRed:avgR / avgCount
                                   green:avgG / avgCount
                                    blue:avgB / avgCount
                                   alpha:1];
    }
    return [NSColor colorWithSRGBRed:binR[best] / binWeight[best]
                               green:binG[best] / binWeight[best]
                                blue:binB[best] / binWeight[best]
                               alpha:1];
}

@end
