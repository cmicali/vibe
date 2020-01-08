//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "Fonts.h"

@implementation Fonts {

}

+ (NSFont *)fontForNumbers:(CGFloat)size {
    return [self fontForNumbers:size bold:NO];
}

+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold {
    return [NSFont monospacedDigitSystemFontOfSize:size weight:bold?NSFontWeightBold:NSFontWeightRegular];
}

+ (NSFont *)font:(CGFloat)size {
    return [NSFont fontWithName:@"HelveticaNeue-Medium" size:size];
}

+ (NSMutableAttributedString *) stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size {
    return [[NSMutableAttributedString alloc] initWithString:str
                                                  attributes:@{
            NSForegroundColorAttributeName:color,
            NSKernAttributeName:@(-0.3),
            NSFontAttributeName:[Fonts fontForNumbers:size]
    }];
}

+ (NSMutableAttributedString *) stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size alignment:(NSTextAlignment)alignment {
    return [self stringForNumbers:str color:color size:size alignment:alignment kerning:-0.3];
}

+ (NSMutableAttributedString *) stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size alignment:(NSTextAlignment)alignment kerning:(CGFloat)kerning {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = alignment;
    return [[NSMutableAttributedString alloc] initWithString:str
                                                  attributes:@{
                                                          NSForegroundColorAttributeName:color,
                                                          NSKernAttributeName:@(kerning),
                                                          NSFontAttributeName:[Fonts fontForNumbers:size],
                                                          NSParagraphStyleAttributeName:paragraph,
                                                  }];
}

+ (NSMutableAttributedString *) string:(NSString *)str color:(NSColor *)color size:(CGFloat)size {
    return [[NSMutableAttributedString alloc] initWithString:str
                                                  attributes:@{
          NSForegroundColorAttributeName:color,
          NSKernAttributeName:@(-0.3),
          NSFontAttributeName:[Fonts font:size]
    }];
}

@end
