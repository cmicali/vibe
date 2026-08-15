//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSDraggingImageComponent+Util.h"
#import "Fonts.h"
#import "NSImage+Util.h"

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

    // NSImage+Util's shared sRGB bitmap-context helper; a failed context
    // degrades to an empty image so the drag still shows the icon.
    NSImage *stringImage = [NSImage imageWithSize:labelSize drawnBy:^{
        [attrStr drawInRect:NSMakeRect(0, 0, labelSize.width, labelSize.height)];
    }] ?: [[NSImage alloc] initWithSize:labelSize];

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
