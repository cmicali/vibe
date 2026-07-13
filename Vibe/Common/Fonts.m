//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "Fonts.h"

@implementation Fonts {

}

+ (NSFont *)font:(CGFloat)size {
    return [self font:size bold:NO];
}

+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSNumber *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSNumber *key = @(bold ? -size : size);
    NSFont *font = cache[key];
    if (!font) {
        font = [NSFont fontWithName:bold ? @"HelveticaNeue-Bold" : @"HelveticaNeue-Medium" size:size];
        if (!font) {
            // Never return nil: callers put the result straight into
            // attribute dictionaries, where nil raises.
            font = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightMedium];
        }
        cache[key] = font;
    }
    return font;
}

+ (NSFont *)fontForNumbers:(CGFloat)size {
    return [self fontForNumbers:size bold:NO];
}

+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSNumber *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSNumber *key = @(bold ? -size : size);
    NSFont *font = cache[key];
    if (!font) {
        font = [NSFont monospacedDigitSystemFontOfSize:size weight:bold?NSFontWeightBold:NSFontWeightRegular];
        cache[key] = font;
    }
    return font;
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
