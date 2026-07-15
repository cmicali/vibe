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

// Cache key: negating the size for bold collides at size 0, so the key spells
// out both dimensions.
static NSString *fontCacheKey(CGFloat size, BOOL bold) {
    return [NSString stringWithFormat:@"%g%@", size, bold ? @"-bold" : @""];
}

+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSString *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSString *key = fontCacheKey(size, bold);
    // NSMutableDictionary isn't thread-safe and not every caller is on the
    // main thread; a duplicate create inside the lock is harmless.
    @synchronized (cache) {
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
}

+ (NSFont *)fontForNumbers:(CGFloat)size {
    return [self fontForNumbers:size bold:NO];
}

+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSString *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSString *key = fontCacheKey(size, bold);
    @synchronized (cache) {
        NSFont *font = cache[key];
        if (!font) {
            font = [NSFont monospacedDigitSystemFontOfSize:size weight:bold?NSFontWeightBold:NSFontWeightRegular];
            cache[key] = font;
        }
        return font;
    }
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
