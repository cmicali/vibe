//
// Created by Christopher Micali on 1/4/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSThread (Blocks)

- (void)performBlock:(void (^)(void))block;
+ (void)performBlockInBackground:(void (^)(void))block;

@end
