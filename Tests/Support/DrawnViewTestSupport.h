//
//  DrawnViewTestSupport.h
//  VibeTests
//
//  Renders a view or a layer tree into a 1x bitmap with no window server, and
//  reads a pixel by the view's own coordinates. The drawn-view tests assert
//  facts about the result, never against a stored reference image.
//

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSBitmapImageRep *VibeBlankBitmap(NSSize size) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:(NSInteger)size.width
                          pixelsHigh:(NSInteger)size.height
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
    rep.size = size;
    return rep;
}

// drawRect: and every subview's, as AppKit would draw them.
static inline NSBitmapImageRep *VibeRenderView(NSView *view) {
    NSBitmapImageRep *rep = VibeBlankBitmap(view.bounds.size);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

// A layer-hosting view draws nothing in drawRect:, so its tree is rendered
// as the compositor's model. Bottom-left origin, like an unflipped view.
static inline NSBitmapImageRep *VibeRenderLayer(CALayer *layer) {
    NSBitmapImageRep *rep = VibeBlankBitmap(layer.bounds.size);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [layer renderInContext:context.CGContext];
    [context flushGraphics];
    return rep;
}

// The pixel under a point in an unflipped (or flipped) view's coordinates.
static inline NSColor *VibePixel(NSBitmapImageRep *rep, BOOL flipped, CGFloat x, CGFloat y) {
    NSInteger column = (NSInteger)floor(x);
    NSInteger row = flipped ? (NSInteger)floor(y) : rep.pixelsHigh - 1 - (NSInteger)floor(y);
    return [[rep colorAtX:column y:row] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

static inline BOOL VibeBitmapIsBlank(NSBitmapImageRep *rep) {
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            if ([rep colorAtX:x y:y].alphaComponent > 0) {
                return NO;
            }
        }
    }
    return YES;
}

static inline BOOL VibeColorsClose(NSColor *a, NSColor *b, CGFloat tolerance) {
    NSColor *ca = [a colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *cb = [b colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return fabs(ca.redComponent - cb.redComponent) <= tolerance
        && fabs(ca.greenComponent - cb.greenComponent) <= tolerance
        && fabs(ca.blueComponent - cb.blueComponent) <= tolerance
        && fabs(ca.alphaComponent - cb.alphaComponent) <= tolerance;
}

// A window that is never ordered front, so nothing reaches a window server.
static inline NSWindow *VibeOffscreenWindow(NSSize size) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    return window;
}

NS_ASSUME_NONNULL_END
