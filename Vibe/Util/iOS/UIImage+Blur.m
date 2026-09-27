//
//  UIImage+Blur.m
//  Vibe (iOS)
//

#import "UIImage+Blur.h"

#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>

// The long side, in pixels, the source is downsampled to before blurring:
// the whole cost.
static const CGFloat kBackdropExtent = 64;

// A fraction of the box, so the softness is scale-free.
static const CGFloat kBackdropBlurFraction = 0.14;

// Black over the blur, so the pager's light text reads over any artwork.
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

    // Opaque: no premultiplication for the box passes to handle.
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

// Three box passes approximate a gaussian. vImage cannot convolve in place,
// so the passes ping-pong through a scratch buffer.
- (void)vibeBoxBlurContext:(CGContextRef)ctx width:(size_t)width height:(size_t)height {
    CGFloat radius = kBackdropExtent * kBackdropBlurFraction;
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
