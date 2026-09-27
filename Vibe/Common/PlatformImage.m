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
// The mac header renders at most ~525px.
const CGFloat kVibeArchivedDisplayArtDimension = 640.0;
#else
// Matches kVibeDisplayArtDimension, so the sidecar is pixel-equivalent to the
// live decode it stands in for.
const CGFloat kVibeArchivedDisplayArtDimension = 1024.0;
#endif

CGSize VibeEncodedImagePixelSize(NSData *data) {
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    if (!source) {
        return CGSizeZero;
    }
    NSDictionary *properties = CFBridgingRelease(
            CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    return CGSizeMake([properties[(id)kCGImagePropertyPixelWidth] doubleValue],
                      [properties[(id)kCGImagePropertyPixelHeight] doubleValue]);
}

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

static const size_t kDominantSampleSide = 32;
static const NSInteger kDominantHueBins = 12;
// Under ~2% vivid pixels is a monochrome cover: a hue from that little signal
// would be random.
static const double kDominantVividFloor = 0.02;

// CoreGraphics rather than either platform's bitmap type, so one pixel loop
// serves both.
static CGImageRef VibeCGImageOfImage(VibeImage *image) {
#if TARGET_OS_OSX
    return [image CGImageForProposedRect:NULL context:nil hints:nil];
#else
    return image.CGImage;
#endif
}

// side x side, sRGB, 8-bit, premultiplied alpha last; row 0 is the image's
// TOP. The caller frees it; NULL when the image cannot be rasterized.
static unsigned char *_Nullable VibeSampledPixels(VibeImage *_Nullable image, size_t side) {
    CGImageRef source = image ? VibeCGImageOfImage(image) : NULL;
    if (!source) {
        return NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) {
        return NULL;
    }
    const size_t bytesPerRow = side * 4;
    unsigned char *data = calloc(side * bytesPerRow, 1);
    if (!data) {
        CGColorSpaceRelease(space);
        return NULL;
    }
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast
            | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(data, side, side, 8, bytesPerRow, space,
                                                 bitmapInfo);
    CGColorSpaceRelease(space);
    if (!context) {
        free(data);
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), source);
    CGContextRelease(context);
    return data;
}

// One sampled pixel as straight sRGB, or NO when too transparent to count.
static BOOL VibeOpaquePixelRGB(const unsigned char *px, double *r, double *g, double *b) {
    double a = px[3] / 255.0;
    if (a < 0.5) {
        return NO;
    }
    *r = MIN(1.0, (px[0] / 255.0) / a);
    *g = MIN(1.0, (px[1] / 255.0) / a);
    *b = MIN(1.0, (px[2] / 255.0) / a);
    return YES;
}

BOOL VibeImageLowerBandIsDark(VibeImage *image, CGFloat fraction) {
    const size_t side = kDominantSampleSide;
    unsigned char *data = VibeSampledPixels(image, side);
    if (!data) {
        return YES;
    }
    // Gamma-encoded sRGB taken as-is: the encoded midpoint is where either
    // button color starts to read.
    size_t firstRow = (size_t)floor(side * (1 - clampRange(fraction, 0, 1)));
    double luminance = 0;
    NSInteger count = 0;
    for (size_t y = firstRow; y < side; y++) {
        const unsigned char *row = data + y * side * 4;
        for (size_t x = 0; x < side; x++) {
            double r, g, b;
            if (!VibeOpaquePixelRGB(row + x * 4, &r, &g, &b)) {
                continue;
            }
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b;
            count++;
        }
    }
    free(data);
    return count == 0 || luminance / count < 0.5;
}

VibeColor *VibeDominantColorOfImage(VibeImage *image) {
    const size_t side = kDominantSampleSide;
    const size_t bytesPerRow = side * 4;
    unsigned char *data = VibeSampledPixels(image, side);
    if (!data) {
        return nil;
    }

    // Vivid pixels vote for their hue band; grays and shadows abstain but
    // still feed the monochrome fallback average.
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
            double r, g, b;
            if (!VibeOpaquePixelRGB(row + x * 4, &r, &g, &b)) {
                continue;
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
            // saturation >= 0.15 guarantees delta > 0.
            double delta = maxc - minc;
            double hue;
            if (maxc == r)      hue = fmod((g - b) / delta + 6.0, 6.0) / 6.0;
            else if (maxc == g) hue = ((b - r) / delta + 2.0) / 6.0;
            else                hue = ((r - g) / delta + 4.0) / 6.0;
            double weight = saturation * brightness;
            // Red straddles the hue seam: rounding plus the modulo lands both
            // edges in bin 0, where flooring would split red's vote in two.
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
    // UIColor's component initializer is already sRGB.
    return [UIColor colorWithRed:red green:green blue:blue alpha:1];
#endif
}
