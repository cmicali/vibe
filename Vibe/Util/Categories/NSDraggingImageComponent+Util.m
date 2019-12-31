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

    NSSize textSize = [attrStr size];
    NSRect textRect = { { NSMidX(imageRect) - textSize.width / 2.0, NSMinY(imageRect) }, textSize };

    textRect.origin.y = -textRect.size.height - 8;
    textRect.size.width += (20.0 - textRect.size.height) * 2.0;
    textRect.size.height = 20.0;

    NSImage *stringImage = [[NSImage alloc] initWithSize:textRect.size];
    [stringImage lockFocus];
    [attrStr drawAtPoint:NSZeroPoint];
    [stringImage unlockFocus];

    NSDraggingImageComponent *labelComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentLabelKey];
    labelComponent.contents = stringImage;
    labelComponent.frame = textRect;

    return labelComponent;
}


@end
