//
//  UIImage+Blur.m
//  Vibe (iOS)
//

#import "UIImage+Blur.h"

#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>

// The box the source is downsampled into before it is blurred, in pixels on the
// long side. Everything about the cost lives here: the blur runs over this many
// pixels whatever the artwork's real size and whatever size it is shown at.
static const CGFloat kBackdropExtent = 64;

// The blur's radius as a fraction of that box, so the result is scale-free —
// the same visual softness at any display size.
static const CGFloat kBackdropBlurFraction = 0.14;

// Black laid over the blur. The pager's text and waveform are drawn light and
// have to read over arbitrary artwork, which is the whole job the dark material
// this replaces was doing.
static const CGFloat kBackdropDarkening = 0.45;

@implementation UIImage (VibeBlur)

- (UIImage *)vibeBlurredBackdrop {
    UIImage *memoized = objc_getAssociatedObject(self, _cmd);
    if (memoized) {
        return memoized;
    }
    UIImage *backdrop = [self vibeRenderBlurredBackdrop];
    if (backdrop) {
        objc_setAssociatedObject(self, _cmd, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return backdrop;
}

- (UIImage *)vibeRenderBlurredBackdrop {
    CGImageRef source = self.CGImage;
    if (!source) {
        return nil;
    }
    size_t sourceWidth = CGImageGetWidth(source);
    size_t sourceHeight = CGImageGetHeight(source);
    if (sourceWidth == 0 || sourceHeight == 0) {
        return nil;
    }
    CGFloat scale = kBackdropExtent / (CGFloat)MAX(sourceWidth, sourceHeight);
    size_t width = MAX((size_t)lround((CGFloat)sourceWidth * scale), (size_t)1);
    size_t height = MAX((size_t)lround((CGFloat)sourceHeight * scale), (size_t)1);

    // Opaque throughout — artwork has no transparency to preserve, and an
    // alpha-free context keeps the box passes from having to reason about
    // premultiplication.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, space, bitmapInfo);
    CGColorSpaceRelease(space);
    if (!ctx) {
        return nil;
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), source);

    [self vibeBoxBlurContext:ctx width:width height:height];

    // The darkening goes into the bake rather than onto a view above it: one
    // layer to composite instead of two, and nothing left to keep in step.
    CGContextSetRGBFillColor(ctx, 0, 0, 0, kBackdropDarkening);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

    CGImageRef blurred = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!blurred) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:blurred];
    CGImageRelease(blurred);
    return result;
}

// Three box passes over the context's pixels in place, the standard gaussian
// approximation. vImage cannot convolve in place, so the passes ping-pong
// through one scratch buffer and land back in the context's own on the third.
- (void)vibeBoxBlurContext:(CGContextRef)ctx width:(size_t)width height:(size_t)height {
    CGFloat radius = kBackdropExtent * kBackdropBlurFraction;
    // The kernel width whose three box passes match a gaussian of that radius.
    uint32_t kernel = (uint32_t)floor(radius * 3 * sqrt(2 * M_PI) / 4 + 0.5);
    kernel |= 1;  // vImage requires an odd kernel
    if (kernel < 3) {
        return;
    }
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(ctx);
    void *scratchBytes = malloc(bytesPerRow * height);
    if (!scratchBytes) {
        return;
    }
    vImage_Buffer inBuffer = {
        .data = CGBitmapContextGetData(ctx), .width = width, .height = height,
        .rowBytes = bytesPerRow
    };
    vImage_Buffer scratch = {
        .data = scratchBytes, .width = width, .height = height, .rowBytes = bytesPerRow
    };
    vImage_Flags flags = kvImageEdgeExtend;
    vImageBoxConvolve_ARGB8888(&inBuffer, &scratch, NULL, 0, 0, kernel, kernel, NULL, flags);
    vImageBoxConvolve_ARGB8888(&scratch, &inBuffer, NULL, 0, 0, kernel, kernel, NULL, flags);
    vImageBoxConvolve_ARGB8888(&inBuffer, &scratch, NULL, 0, 0, kernel, kernel, NULL, flags);
    memcpy(inBuffer.data, scratchBytes, bytesPerRow * height);
    free(scratchBytes);
}

@end
