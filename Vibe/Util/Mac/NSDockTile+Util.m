//
//  NSDockTile+Util.m
//  Vibe
//

#import "NSDockTile+Util.h"
#import "NSImage+Util.h"

// So a slow composition cannot overwrite a newer icon or a reset. Main thread
// only, so unlocked.
static NSUInteger VibeDockIconGeneration = 0;

static const CGFloat kVibeDockIconCanvasSize = 512;

// TRAP: setting the tile's contentView to nil and installing a view again
// leaks a 256KB dock-tile context per transition (788MB over a 42-minute
// soak). So one view is installed and only its image swaps; the tile never
// sees nil again, which is why the reset draws the icon into it.
static NSImageView *VibeDockIconView = nil;
static NSImage *VibeDockAppIcon = nil;

static NSImageView *VibeInstalledDockIconView(void) {
    if (!VibeDockIconView) {
        // TRAP: applicationIconImage is nil before launch finishes (the
        // player controller is built in applicationWillFinishLaunching:), and
        // a cached nil paints a transparent tile all session; imageNamed:
        // covers it.
        VibeDockAppIcon = [NSApp applicationIconImage]
                ?: [NSImage imageNamed:NSImageNameApplicationIcon];
        VibeDockIconView = [[NSImageView alloc] initWithFrame:
                            NSMakeRect(0, 0, kVibeDockIconCanvasSize, kVibeDockIconCanvasSize)];
        // TRAP: the default scaling never enlarges, and the app icon reports
        // 256pt (512px at 2x), so it would draw at half the canvas.
        VibeDockIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    }
    // TRAP: assigning NSApp.applicationIconImage drops the content view, so an
    // image on a detached view shows nothing. Re-attach on every install.
    if ([NSApp dockTile].contentView != VibeDockIconView) {
        [[NSApp dockTile] setContentView:VibeDockIconView];
    }
    return VibeDockIconView;
}

@implementation NSDockTile (Util)

+ (void) resetToAppIcon {
    VibeDockIconGeneration++;
    // No view yet means the Dock still draws the real icon; installing one at
    // launch would show nothing.
    if (!VibeDockIconView) {
        return;
    }
    // Live, so a theme's custom icon reads through; the capture covers nil.
    VibeInstalledDockIconView().image = [NSApp applicationIconImage] ?: VibeDockAppIcon;
    [[NSApp dockTile] display];
}

// The system icon grid: content spans 824 of 1,024 points with a 185-point
// corner radius. The Dock draws a contentView edge to edge, so anything with
// less margin reads larger than its neighbors. nil when there is no context.
static NSImage* CreateMacStyleIconFromImage(NSImage *sourceImage, CGFloat canvasSize) {

    CGFloat size = canvasSize * (824.0 / 1024.0);
    CGFloat margin = (canvasSize - size) / 2;
    CGFloat cornerRadius = size * (185.0 / 824.0);
    // About 1.5 device pixels at Dock size.
    CGFloat rimWidth = size * 0.015;
    CGFloat shadowBlur = size * 0.06;
    CGFloat shadowOffsetY = -size * 0.03;

    return [NSImage imageWithSize:NSMakeSize(canvasSize, canvasSize) drawnBy:^{

        // The margin contains the shadow (blur plus offset is ~0.09 × size).
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
    
        [[NSColor clearColor] setFill];
        [clipPath fill];

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

        // A rim light approximating the system bevel on Icon Composer icons.
        // A double-width stroke clipped to the shape leaves the inner band.
        CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
        CGContextSaveGState(ctx);
        CGPathRef rimPath = CGPathCreateWithRoundedRect(drawingRect, cornerRadius, cornerRadius, NULL);
        CGContextAddPath(ctx, rimPath);
        CGContextSetLineWidth(ctx, rimWidth * 2);
        CGContextReplacePathWithStrokedPath(ctx);
        CGContextClip(ctx);
        NSGradient *rim = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.28]
                                                        endingColor:[NSColor colorWithWhite:1 alpha:0.55]];
        [rim drawInRect:drawingRect angle:90]; // brightest on top
        CGPathRelease(rimPath);
        CGContextRestoreGState(ctx);

    }];
}

+ (void)setDockIcon:(NSImage*)image shaped:(BOOL)shaped {
    CGFloat size = kVibeDockIconCanvasSize;
    NSUInteger generation = ++VibeDockIconGeneration;
    // Every theme apply re-installs the same instance, so reuse its
    // composition with no hop.
    static NSImage *composedFrom = nil, *composed = nil;
    if (!shaped || image == composedFrom) {
        VibeInstalledDockIconView().image = shaped ? composed : image;
        [[NSApp dockTile] display];
        return;
    }
    // Copy before hopping queues: the artwork views draw the caller's
    // instance on main, and NSImageRep's first-draw caching is not documented
    // thread-safe.
    NSImage *imageCopy = [image copy];
    // Off main: a several-ms render that would land at track start.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *customIcon = CreateMacStyleIconFromImage(imageCopy, size);
        if (!customIcon) {
            return;
        }
        run_on_main_thread({
            if (generation != VibeDockIconGeneration) {
                return;
            }
            composedFrom = image;
            composed = customIcon;
            VibeInstalledDockIconView().image = customIcon;
            [[NSApp dockTile] display];
        });
    });
}

+ (void)setAppIcon:(NSImage *)image shaped:(BOOL)shaped {
    // Memoized on the source instance: every theme apply re-requests this.
    static NSImage *composedFrom = nil, *composed = nil, *assigned = nil;
    if (image && shaped && image != composedFrom) {
        composed = CreateMacStyleIconFromImage(image, kVibeDockIconCanvasSize);
        composedFrom = image;
    }
    NSImage *icon = !image ? nil : shaped ? composed : image;
    // Only on a change: each assignment drops the art tile's content view
    // (VibeInstalledDockIconView).
    if (icon != assigned) {
        assigned = icon;
        NSApp.applicationIconImage = icon;
    }
}

@end
