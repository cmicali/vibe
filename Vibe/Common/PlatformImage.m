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
const CGFloat kVibeArchivedDisplayArtDimension = 640.0;

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
