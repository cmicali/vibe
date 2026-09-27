//
//  NSDraggingImageComponent+Util.m
//  Vibe
//

#import "NSDraggingImageComponent+Util.h"
#import "Fonts.h"
#import "NSImage+Util.h"

@implementation NSDraggingImageComponent (Util)

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

    // Drawn in a rect, not at a point, so the centered alignment applies.
    NSSize textSize = [attrStr size];
    NSSize labelSize = NSMakeSize(ceil(textSize.width), ceil(textSize.height));

    // A failed context degrades to an empty image; the drag keeps its icon.
    NSImage *stringImage = [NSImage imageWithSize:labelSize drawnBy:^{
        [attrStr drawInRect:NSMakeRect(0, 0, labelSize.width, labelSize.height)];
    }] ?: [[NSImage alloc] initWithSize:labelSize];

    NSDraggingImageComponent *labelComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentLabelKey];
    labelComponent.contents = stringImage;
    // 8pt below the icon, in the dragging item's space.
    labelComponent.frame = NSMakeRect(NSMidX(imageRect) - labelSize.width / 2.0,
                                      NSMinY(imageRect) - labelSize.height - 8,
                                      labelSize.width, labelSize.height);

    return labelComponent;
}


@end
