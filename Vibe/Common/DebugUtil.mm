//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugUtil.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>

static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
}

static void VibeDumpWindowSnapshot(void) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) {
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.contentView) {
                window = candidate;
                break;
            }
        }
    }
    NSView *view = window.contentView;
    if (!view || NSIsEmptyRect(view.bounds)) {
        LogError(@"Debug screenshot: no window content to render");
        return;
    }
    CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0;
    size_t pixelsWide = (size_t)llround(view.bounds.size.width * scale);
    size_t pixelsHigh = (size_t)llround(view.bounds.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
            kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        return;
    }
    CGContextScaleCTM(ctx, scale, scale);
    CALayer *layer = view.layer;
    if (layer) {
        // Presentation tree when available: captures animations mid-flight.
        CALayer *presentation = layer.presentationLayer ?: layer;
        [presentation renderInContext:ctx];
    }
    else {
        // Non-layer-backed fallback: AppKit drawing path.
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [view displayRectIgnoringOpacity:view.bounds inContext:gc];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) {
        return;
    }
    NSString *path = VibeDebugScreenshotPath();
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
        LogInfo(@"Debug screenshot written to %@", path);
    }
    CGImageRelease(image);
}

void VibeInstallDebugScreenshotHook(void) {
    static int token;
    notify_register_dispatch("com.vibe.debug.screenshot", &token, dispatch_get_main_queue(), ^(int t) {
        VibeDumpWindowSnapshot();
    });
}

#endif
