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
    } else if (self.isCancelled || self.isFinished) {
        // A block queued to a dead runloop would never execute; make the
        // drop visible instead of silent.
        LogWarn(@"NSThread run: dropping block, thread '%@' is %@",
                self.name.length ? self.name : self,
                self.isCancelled ? @"cancelled" : @"finished");
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
