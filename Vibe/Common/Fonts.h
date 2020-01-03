//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Fonts : NSObject

+ (NSFont *)fontForNumbers:(CGFloat)size;

+ (NSFont *)font:(CGFloat)size;

+ (NSMutableAttributedString *)stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size;

+ (NSMutableAttributedString *)stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size alignment:(NSTextAlignment)alignment;

+ (NSMutableAttributedString *)stringForNumbers:(NSString *)str color:(NSColor *)color size:(CGFloat)size alignment:(NSTextAlignment)alignment kerning:(CGFloat)kerning;

+ (NSMutableAttributedString *)string:(NSString *)str color:(NSColor *)color size:(CGFloat)size;
@end
