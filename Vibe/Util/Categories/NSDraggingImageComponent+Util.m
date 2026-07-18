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

    // Sized from the string's metrics; drawing in a rect (not at a point) is
    // what makes the centered alignment apply.
    NSSize textSize = [attrStr size];
    NSSize labelSize = NSMakeSize(ceil(textSize.width), ceil(textSize.height));

    NSImage *stringImage = [[NSImage alloc] initWithSize:labelSize];
    [stringImage lockFocus];
    [attrStr drawInRect:NSMakeRect(0, 0, labelSize.width, labelSize.height)];
    [stringImage unlockFocus];

    NSDraggingImageComponent *labelComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentLabelKey];
    labelComponent.contents = stringImage;
    // Centered 8pt below the icon (component frames are in the dragging
    // item's space, so this hangs below draggingFrame).
    labelComponent.frame = NSMakeRect(NSMidX(imageRect) - labelSize.width / 2.0,
                                      NSMinY(imageRect) - labelSize.height - 8,
                                      labelSize.width, labelSize.height);

    return labelComponent;
}


@end
