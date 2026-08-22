//
//  PlatformImage.m
//  Vibe
//

#import "PlatformImage.h"
#import <ImageIO/ImageIO.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

const CGFloat kVibeThumbnailArtDimension = 128.0;
const CGFloat kVibeDisplayArtDimension = 1024.0;
#if TARGET_OS_OSX
// The mac header renders at most ~525px, so 640 leaves headroom for less disk.
const CGFloat kVibeArchivedDisplayArtDimension = 640.0;
#else
// The iOS now-playing page is full-screen at 3x, and its live decode caps at
// kVibeDisplayArtDimension — the rendition matches that bound exactly, so the
// sidecar is pixel-equivalent to the decode it stands in for.
const CGFloat kVibeArchivedDisplayArtDimension = 1024.0;
#endif

VibeImage *VibeDecodedImageWithData(NSData *data, CGFloat maxPixelSize) {
    if (!data) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return nil;
    }
    NSDictionary *options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (id)kCGImageSourceShouldCacheImmediately: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) {
        return nil;
    }
#if TARGET_OS_OSX
    VibeImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
#else
    VibeImage *image = [UIImage imageWithCGImage:cgImage];
#endif
    CGImageRelease(cgImage);
    return image;
}

// 1024 samples is plenty to pick one color out of a cover.
static const size_t kDominantSampleSide = 32;
static const NSInteger kDominantHueBins = 12;
// Under about 2% of pixels vivid means a monochrome cover, and its overall gray
// is the honest answer. A hue teased out of that little signal would tint it a
// random color.
static const double kDominantVividFloor = 0.02;

// The platform image as a CGImage. This — rather than each platform's own
// bitmap type — is what lets one implementation serve both: NSBitmapImageRep
// and UIImage's backing store agree on nothing, while CoreGraphics draws either
// into a context we control the layout of.
static CGImageRef VibeCGImageOfImage(VibeImage *image) {
#if TARGET_OS_OSX
    return [image CGImageForProposedRect:NULL context:nil hints:nil];
#else
    return image.CGImage;
#endif
}

VibeColor *VibeDominantColorOfImage(VibeImage *image) {
    CGImageRef source = image ? VibeCGImageOfImage(image) : NULL;
    if (!source) {
        return nil;
    }
    // Drawn into a context whose layout we dictate — sRGB, 8-bit, alpha last,
    // premultiplied — so the pixel loop below reads a known buffer instead of
    // interrogating whatever the source happened to be encoded as.
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) {
        return nil;
    }
    const size_t side = kDominantSampleSide;
    const size_t bytesPerRow = side * 4;
    unsigned char *data = calloc(side * bytesPerRow, 1);
    if (!data) {
        CGColorSpaceRelease(space);
        return nil;
    }
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast
            | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(data, side, side, 8, bytesPerRow, space,
                                                 bitmapInfo);
    CGColorSpaceRelease(space);
    if (!context) {
        free(data);
        return nil;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), source);
    CGContextRelease(context);

    // A weighted hue histogram. Vivid pixels — saturated and not near-black —
    // vote for their hue band, while grays and shadows abstain but still feed
    // the monochrome fallback average.
    double binWeight[kDominantHueBins], binR[kDominantHueBins];
    double binG[kDominantHueBins], binB[kDominantHueBins];
    memset(binWeight, 0, sizeof(binWeight));
    memset(binR, 0, sizeof(binR));
    memset(binG, 0, sizeof(binG));
    memset(binB, 0, sizeof(binB));
    double avgR = 0, avgG = 0, avgB = 0;
    NSInteger avgCount = 0;
    for (size_t y = 0; y < side; y++) {
        const unsigned char *row = data + y * bytesPerRow;
        for (size_t x = 0; x < side; x++) {
            const unsigned char *px = row + x * 4;
            double a = px[3] / 255.0;
            if (a < 0.5) {
                continue;
            }
            // Premultiplied by the context's own format, so always un-multiply.
            double r = MIN(1.0, (px[0] / 255.0) / a);
            double g = MIN(1.0, (px[1] / 255.0) / a);
            double b = MIN(1.0, (px[2] / 255.0) / a);
            avgR += r; avgG += g; avgB += b;
            avgCount++;
            double maxc = MAX(r, MAX(g, b));
            double minc = MIN(r, MIN(g, b));
            double brightness = maxc;
            double saturation = maxc > 0 ? (maxc - minc) / maxc : 0;
            if (saturation < 0.15 || brightness < 0.1) {
                continue;
            }
            // A saturation of 0.15 or more guarantees maxc > minc, so delta > 0.
            double delta = maxc - minc;
            double hue;
            if (maxc == r)      hue = fmod((g - b) / delta + 6.0, 6.0) / 6.0;
            else if (maxc == g) hue = ((b - r) / delta + 2.0) / 6.0;
            else                hue = ((r - g) / delta + 4.0) / 6.0;
            double weight = saturation * brightness;
            // Hue wraps, and red straddles the 0.0-to-1.0 seam, so round to the
            // nearest bin center and fold with a modulo, which lands both edges
            // in bin 0. Flooring instead split red's vote across the first and
            // last bins, penalizing red covers alone in the election.
            NSInteger bin = ((NSInteger)lround(hue * kDominantHueBins)) % kDominantHueBins;
            binWeight[bin] += weight;
            binR[bin] += r * weight;
            binG[bin] += g * weight;
            binB[bin] += b * weight;
        }
    }
    free(data);
    if (avgCount == 0) {
        return nil;
    }
    NSInteger best = 0;
    for (NSInteger i = 1; i < kDominantHueBins; i++) {
        if (binWeight[i] > binWeight[best]) {
            best = i;
        }
    }
    double red, green, blue;
    if (binWeight[best] < kDominantVividFloor * side * side) {
        red = avgR / avgCount; green = avgG / avgCount; blue = avgB / avgCount;
    }
    else {
        red = binR[best] / binWeight[best];
        green = binG[best] / binWeight[best];
        blue = binB[best] / binWeight[best];
    }
#if TARGET_OS_OSX
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:1];
#else
    // UIColor's component initializer is sRGB, matching the context above.
    return [UIColor colorWithRed:red green:green blue:blue alpha:1];
#endif
}
