//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSDraggingImageComponent+Util.h"
#import "Fonts.h"

@implementation NSDraggingImageComponent (Util)

+ (NSDraggingImageComponent *)labelWithFile:(NSURL *)file imageRect:(CGRect)imageRect {
    return [self labelWithString:[file.path lastPathComponent] imageRect:imageRect];
}

+ (NSDraggingImageComponent *)labelWithString:(NSString *)string imageRect:(CGRect)imageRect {

    NSMutableParagraphStyle *centered = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    centered.alignment = NSTextAlignmentCenter;
    NSAttributedString *attrStr = [[NSAttributedString alloc]
                                                       initWithString:[@[@" ", string, @" "] componentsJoinedByString:@""]
                                                           attributes:@{
                                                                   NSFontAttributeName: [Fonts font:14],
                                                                   NSParagraphStyleAttributeName: centered,
                                                                   NSForegroundColorAttributeName: [NSColor whiteColor],
                                                                   NSBackgroundColorAttributeName: [[NSColor blackColor] colorWithAlphaComponent:0.5],
                                                           }
    ];

    // Sized from the string's metrics. Drawing in a rect, rather than at a
    // point, is what makes the centered alignment apply.
    NSSize textSize = [attrStr size];
    NSSize labelSize = NSMakeSize(ceil(textSize.width), ceil(textSize.height));

    // An explicit sRGB bitmap context rather than lockFocus, which is
    // soft-deprecated and whose backing rep picks up the deepest screen's
    // scale. Same pattern as NSDockTile+Util and NSImage+Util.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                                               initWithBitmapDataPlanes:NULL
                                                             pixelsWide:(NSInteger)labelSize.width
                                                             pixelsHigh:(NSInteger)labelSize.height
                                                          bitsPerSample:8
                                                        samplesPerPixel:4
                                                               hasAlpha:YES
                                                               isPlanar:NO
                                                         colorSpaceName:NSCalibratedRGBColorSpace
                                                            bytesPerRow:0
                                                           bitsPerPixel:0];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    NSGraphicsContext *context = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
    NSImage *stringImage = [[NSImage alloc] initWithSize:labelSize];
    if (context) {
        rep.size = labelSize;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        [attrStr drawInRect:NSMakeRect(0, 0, labelSize.width, labelSize.height)];
        [NSGraphicsContext restoreGraphicsState];
        [stringImage addRepresentation:rep];
    }

    NSDraggingImageComponent *labelComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentLabelKey];
    labelComponent.contents = stringImage;
    // Centered 8pt below the icon. Component frames sit in the dragging item's
    // space, so this hangs below draggingFrame.
    labelComponent.frame = NSMakeRect(NSMidX(imageRect) - labelSize.width / 2.0,
                                      NSMinY(imageRect) - labelSize.height - 8,
                                      labelSize.width, labelSize.height);

    return labelComponent;
}


@end
