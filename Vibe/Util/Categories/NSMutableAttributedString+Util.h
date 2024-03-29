//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSMutableAttributedString (Util)

@property (nonatomic, strong) NSDictionary *textAttributes;

- (id)initWithAttributes:(NSDictionary *)attributes;
- (id)initWithColor:(NSColor *)color;
- (id)initWithKerning:(CGFloat)kerning;

- (void)appendString:(NSString *)string;

@end
