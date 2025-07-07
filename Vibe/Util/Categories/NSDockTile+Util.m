//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSDockTile+Util.h"

@implementation NSDockTile (Util)

+ (void) resetToAppIcon {
    NSDockTile *dockTile = [[NSApplication sharedApplication] dockTile];
    NSImage *image = [NSApplication sharedApplication].applicationIconImage;
    NSImageView *iv = [NSImageView imageViewWithImage:image];
    [[NSApplication sharedApplication] dockTile].contentView = iv;
    [dockTile display];
}

NSImage* CreateMacStyleIconFromImage(NSImage *sourceImage, CGFloat size) {
    
    CGFloat cornerRadius = size * 0.18;
    CGFloat borderWidth = 12.0;
    CGFloat shadowBlur = size * 0.06;
    CGFloat shadowOffsetY = -size * 0.03;

    NSRect rect = NSMakeRect(0, 0, size, size);
    
    // Add padding for shadow
    CGFloat shadowPadding = shadowBlur + fabs(shadowOffsetY);
    NSSize finalSize = NSMakeSize(size + shadowPadding * 2, size + shadowPadding * 2);

    NSImage *finalImage = [[NSImage alloc] initWithSize:finalSize];
    [finalImage lockFocus];
    
    // Drawing rectangle that accounts for shadow padding.
    NSRect drawingRect = NSMakeRect(shadowPadding, shadowPadding, size, size);

    // Create the rounded clipping path.
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:drawingRect
                                                              xRadius:cornerRadius
                                                              yRadius:cornerRadius];

    // Save the current graphics state.
    [NSGraphicsContext saveGraphicsState];
    
    // Configure and set the shadow.
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowBlurRadius:shadowBlur];
    [shadow setShadowOffset:NSMakeSize(0, shadowOffsetY)];
    [shadow setShadowColor:[[NSColor blackColor] colorWithAlphaComponent:1]];
    [shadow set];
    
    // Filling the path triggers the shadow drawing.
    [[NSColor clearColor] setFill];
    [clipPath fill];

    // Restore graphics state to remove shadow.
    [NSGraphicsContext restoreGraphicsState];

    // Now clip to the rounded rect for the artwork.
    [clipPath addClip];

    // Scale and center the source image.
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

    // Draw border around the clipped area.
    [[NSColor colorWithWhite:0 alpha:0.7] setStroke];
    [clipPath setLineWidth:borderWidth];
    [clipPath stroke];

    [finalImage unlockFocus];
    [finalImage setSize:finalSize];
    return finalImage;
}

+ (void)setDockIcon:(NSImage*)image {
    CGFloat size = 512;
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    NSImage *customIcon = CreateMacStyleIconFromImage(image, size);
    [iconView setImage:customIcon];
    [[NSApp dockTile] setContentView:iconView];
    [[NSApp dockTile] display];
}

@end
