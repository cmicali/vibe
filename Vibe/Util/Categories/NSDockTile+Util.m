//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSDockTile+Util.h"

// A monotonic ticket, so that a slow background icon composition cannot
// overwrite a newer icon or a reset. Both entry points are main-thread UI
// calls, so no locking is needed: the async completion re-checks it back on
// the main thread.
static NSUInteger VibeDockIconGeneration = 0;

@implementation NSDockTile (Util)

+ (void) resetToAppIcon {
    VibeDockIconGeneration++; // invalidate any in-flight composition
    NSDockTile *dockTile = [[NSApplication sharedApplication] dockTile];
    dockTile.contentView = nil;
    [dockTile display];
}

// Composes the artwork into a dock-icon canvas that matches the system icon
// grid. The Dock renders the tile's contentView edge to edge, and real app
// icons carry built-in transparent margins: the rounded-rect content of a
// standard macOS icon spans 824 of its 1,024-point canvas, with a corner
// radius of about 22.5%, or 185 of 824. Anything with a smaller margin reads
// visibly larger than every neighboring icon in the Dock and the switcher.
//
// It draws into an explicit sRGB NSBitmapImageRep context rather than using
// lockFocus, which is soft-deprecated and whose backing rep also picks up the
// deepest screen's scale. NSImage+Util's resizedImage: follows the same
// pattern. It returns nil if there is no context.
static NSImage* CreateMacStyleIconFromImage(NSImage *sourceImage, CGFloat canvasSize) {

    CGFloat size = canvasSize * (824.0 / 1024.0);
    CGFloat margin = (canvasSize - size) / 2;
    CGFloat cornerRadius = size * (185.0 / 824.0);
    // The rim-light band width: about 1.5 device pixels at Dock size, like the
    // bevel on neighboring icons.
    CGFloat rimWidth = size * 0.015;
    CGFloat shadowBlur = size * 0.06;
    CGFloat shadowOffsetY = -size * 0.03;

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                                               initWithBitmapDataPlanes:NULL
                                                             pixelsWide:(NSInteger)canvasSize
                                                             pixelsHigh:(NSInteger)canvasSize
                                                          bitsPerSample:8
                                                        samplesPerPixel:4
                                                               hasAlpha:YES
                                                               isPlanar:NO
                                                         colorSpaceName:NSCalibratedRGBColorSpace
                                                            bytesPerRow:0
                                                           bitsPerPixel:0];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    NSGraphicsContext *context = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
    if (!context) {
        return nil;
    }
    rep.size = NSMakeSize(canvasSize, canvasSize); // 1 point per pixel: the Dock scales it itself
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    // The content rect, centered on the icon grid. The grid margin comfortably
    // contains the shadow, since the blur plus the offset comes to about 0.09
    // times the size, well under the margin.
    NSRect drawingRect = NSMakeRect(margin, margin, size, size);

    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:drawingRect
                                                              xRadius:cornerRadius
                                                              yRadius:cornerRadius];

    [NSGraphicsContext saveGraphicsState];

    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowBlurRadius:shadowBlur];
    [shadow setShadowOffset:NSMakeSize(0, shadowOffsetY)];
    [shadow setShadowColor:[[NSColor blackColor] colorWithAlphaComponent:1]];
    [shadow set];
    
    // Filling the path triggers the shadow drawing.
    [[NSColor clearColor] setFill];
    [clipPath fill];

    // Restore the graphics state to remove the shadow.
    [NSGraphicsContext restoreGraphicsState];

    [clipPath addClip];

    NSSize srcSize = [sourceImage size];
    CGFloat scale = MIN(size / srcSize.width, size / srcSize.height);
    NSRect targetRect;
    targetRect.size.width = srcSize.width * scale;
    targetRect.size.height = srcSize.height * scale;
    targetRect.origin.x = drawingRect.origin.x + (drawingRect.size.width - targetRect.size.width) / 2.0;
    targetRect.origin.y = drawingRect.origin.y + (drawingRect.size.height - targetRect.size.height) / 2.0;

    [sourceImage drawInRect:targetRect
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0
             respectFlipped:YES
                      hints:nil];

    // A Liquid Glass-style rim light: a thin inner stroke that is brightest
    // along the top edge and fades toward the bottom, approximating the
    // bevel the system renders on real (Icon Composer) icons — without it
    // the artwork tile reads flat next to every neighboring icon. Stroking
    // the clip path at double width while clipped to the icon shape leaves
    // exactly the inner rimWidth-wide band visible.
    CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
    CGContextSaveGState(ctx);
    CGPathRef rimPath = CGPathCreateWithRoundedRect(drawingRect, cornerRadius, cornerRadius, NULL);
    CGContextAddPath(ctx, rimPath);
    CGContextSetLineWidth(ctx, rimWidth * 2);
    CGContextReplacePathWithStrokedPath(ctx);
    CGContextClip(ctx);
    // Mostly uniform with a brighter top, matching the system bevel (which
    // stays visible along an icon's bottom edge too).
    NSGradient *rim = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.28]
                                                    endingColor:[NSColor colorWithWhite:1 alpha:0.55]];
    [rim drawInRect:drawingRect angle:90]; // 90° = bottom → top: brightest on top
    CGPathRelease(rimPath);
    CGContextRestoreGState(ctx);

    [NSGraphicsContext restoreGraphicsState];

    NSImage *finalImage = [[NSImage alloc] initWithSize:NSMakeSize(canvasSize, canvasSize)];
    [finalImage addRepresentation:rep];
    return finalImage;
}

+ (void)setDockIcon:(NSImage*)image {
    CGFloat size = 512;
    NSUInteger generation = ++VibeDockIconGeneration;
    // Copy before hopping queues: the caller's instance is also being drawn
    // by the artwork views on the main thread, and NSImageRep's first-draw
    // caching is not documented thread-safe.
    NSImage *imageCopy = [image copy];
    // Compose off the main thread: the 512px rounded-rect + shadow render
    // (drawing from up-to-1024px art) is a several-ms hitch that would land
    // exactly at track start, alongside waveform hydration and the artwork
    // cross-fades. Only the dock-tile assignment happens on main.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *customIcon = CreateMacStyleIconFromImage(imageCopy, size);
        if (!customIcon) {
            return; // no context — leave whatever icon is showing
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != VibeDockIconGeneration) {
                return; // a newer icon (or a reset to the app icon) won
            }
            NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
            [iconView setImage:customIcon];
            [[NSApp dockTile] setContentView:iconView];
            [[NSApp dockTile] display];
        });
    });
}

@end
