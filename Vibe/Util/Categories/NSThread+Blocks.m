//
// Created by Christopher Micali on 1/4/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "NSThread+Blocks.h"

@implementation NSThread (Blocks)

+ (void)runBlockOnCurrentThread:(void (^)(void))block {
    block();
}

- (void)run:(void (^)(void))block {
    if ([[NSThread currentThread] isEqual:self]) {
        block();
    } else {
        [self performWaitingUntilDone:NO block:block];
    }
}

- (void)performWaitingUntilDone:(BOOL)waitDone block:(void (^)(void))block {
    [NSThread performSelector:@selector(runBlockOnCurrentThread:)
                     onThread:self
                   withObject:block
                waitUntilDone:waitDone];
}

+ (void)runInBackground:(void (^)(void))block {
    [NSThread performSelectorInBackground:@selector(runBlockOnCurrentThread:)
                               withObject:block];
}

@end
