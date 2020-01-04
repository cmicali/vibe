//
// Created by Christopher Micali on 1/4/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSThread (Blocks)

+ (void)runBlockOnCurrentThread:(void (^)(void))block;

- (void)run:(void (^)(void))block;

@end
