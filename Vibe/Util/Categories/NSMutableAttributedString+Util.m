//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSMutableAttributedString+Util.h"
#import <objc/runtime.h>

@implementation NSMutableAttributedString (Util)

- (id)initWithColor:(NSColor*)color {
    self = [self init];
    self.textAttributes = @{
            NSForegroundColorAttributeName:color,
    };
    return self;
}

- (id)initWithKerning:(CGFloat)kerning {
    self = [self init];
    self.textAttributes = @{
            NSKernAttributeName:@(kerning),
    };
    return self;
}

- (id)initWithAttributes:(NSDictionary *)attributes {
    self = [self init];
    self.textAttributes = attributes;
    return self;
}

- (void)appendString:(NSString *)string {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:string attributes:self.textAttributes];
    [self appendAttributedString:as];
}

- (NSDictionary *)textAttributes {
    return objc_getAssociatedObject(self, @selector(textAttributes));
}

- (void)setTextAttributes:(NSDictionary *)textAttributes {
    objc_setAssociatedObject(self, @selector(textAttributes), textAttributes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
