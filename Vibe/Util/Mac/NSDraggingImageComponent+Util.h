//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSDraggingImageComponent (Util)

+ (NSDraggingImageComponent *)labelWithFile:(NSURL *)file imageRect:(CGRect)imageRect;
+ (NSDraggingImageComponent *)labelWithString:(NSString *)string imageRect:(CGRect)imageRect;

@end
