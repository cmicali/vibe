//
//  DebugScreenshot.m
//  Vibe
//
//  Window capture: the notifyutil hook and the per-command dump_screenshot path.
//

#import "DebugInternal.h"

#if DEBUG

// The notifyutil hook's fixed output path. dump_screenshot writes a
// per-command file instead, through VibeDebugScreenshotPathForCommand, so that
// two clients snapshotting back to back cannot hand one client the other's
// pixels.
static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
}

// A glass view's hosting layer renders as opaque white in renderInContext:,
// because its real content is composited by the window server, and it paints
// over everything below it in the tree. It must therefore be hidden for the
// render, not merely underpainted.
static void VibeCollectGlassLayers(NSView *view, NSMutableArray<CALayer *> *out) {
    if (@available(macOS 26.0, *)) {
        if ([view isKindOfClass:[NSGlassEffectView class]]) {
            if (view.layer) {
                [out addObject:view.layer];
            }
            return;
        }
    }
    for (NSView *subview in view.subviews) {
        VibeCollectGlassLayers(subview, out);
    }
}

BOOL VibeDumpWindowSnapshot(NSString *path) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) {
        // Front to back, not creation order: with the app inactive both
        // keyWindow and mainWindow are nil, and NSApp.windows would hand back
        // the player even while the settings or about window sits in front.
        for (NSWindow *candidate in NSApp.orderedWindows) {
            if (candidate.isVisible && candidate.contentView) {
                window = candidate;
                break;
            }
        }
    }
    NSView *view = window.contentView;
    if (!view || NSIsEmptyRect(view.bounds)) {
        LogError(@"Debug screenshot: no window content to render");
        return NO;
    }
    CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0;
    size_t pixelsWide = (size_t)llround(view.bounds.size.width * scale);
    size_t pixelsHigh = (size_t)llround(view.bounds.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        LogError(@"Debug screenshot: bitmap context creation failed");
        return NO;
    }
    CGContextScaleCTM(ctx, scale, scale);
    // With the glass layers hidden below, their region renders transparent, so
    // paint an appearance-matched proxy background first. Dark-mode content —
    // white text and waveform at low alpha — then keeps the window's real
    // contrast polarity rather than flattening onto white.
    NSAppearanceName match = [window.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL isDark = [match isEqualToString:NSAppearanceNameDarkAqua];
    CGContextSetGrayFillColor(ctx, isDark ? 0.1 : 0.95, 1.0);
    CGContextFillRect(ctx, view.bounds);
    CALayer *layer = view.layer;
    if (layer) {
        NSMutableArray<CALayer *> *glassLayers = [NSMutableArray array];
        VibeCollectGlassLayers(view, glassLayers);
        if (glassLayers.count > 0) {
            // The hides must stay uncommitted, so that the on-screen window
            // never flickers. That forces a render of the model tree, since an
            // uncommitted change is invisible to a presentation copy. It costs
            // the mid-flight animation capture, but only glass-bearing windows
            // pay for it.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            for (CALayer *glass in glassLayers) {
                glass.hidden = YES;
            }
            [layer renderInContext:ctx];
            for (CALayer *glass in glassLayers) {
                glass.hidden = NO;
            }
            [CATransaction commit];
        }
        else {
            // The presentation tree where available, which captures animations
            // mid-flight.
            CALayer *presentation = layer.presentationLayer ?: layer;
            [presentation renderInContext:ctx];
        }
    }
    else {
        // The non-layer-backed fallback: AppKit's drawing path.
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [view displayRectIgnoringOpacity:view.bounds inContext:gc];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) {
        LogError(@"Debug screenshot: image creation failed");
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL written = NO;
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        written = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    if (written) {
        LogInfo(@"Debug screenshot written to %@", path);
    }
    else {
        LogError(@"Debug screenshot: PNG write to %@ failed", path);
    }
    return written;
}

void VibeInstallDebugScreenshotHook(void) {
    static int token;
    notify_register_dispatch("com.vibe.debug.screenshot", &token, dispatch_get_main_queue(), ^(int t) {
        VibeDumpWindowSnapshot(VibeDebugScreenshotPath());
    });
}


#endif
