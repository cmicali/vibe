//
// Created by Christopher Micali on 1/4/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "WorkQueueThread.h"


@implementation WorkQueueThread {

}

- (void)main {
    NSRunLoop *nsRunLoop = [NSRunLoop currentRunLoop];
    // According to the NSRunLoop docs, a port must be added to the
    // runloop to keep the loop alive, otherwise when you call
    // runMode:beforeDate: it will immediately return with NO. We never
    // send anything over this port, it's only here to keep the run loop
    // looping.
    [nsRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
    while (true) {
        if (self.isCancelled) {
            break;
        }
        BOOL ranLoop = [nsRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate distantFuture]];
        if (!ranLoop) {
            break;
        }
    }
}

- (void)cancel {
    [super cancel];
    if (![[NSThread currentThread] isEqual:self]) {
        // This call just forces the runloop in main to spin allowing main to see
        // that the isCancelled flag has been set. Note that this is only really
        // needed if there are no blocks/selectors in the queue for the thread. If
        // there are other items to be processed in the queue, the next one will be
        // executed and then the "cancel" will be seen in main, and it will exit
        // (and the other blocks will be dropped).
        [self performSelector:@selector(class)
                     onThread:self
                   withObject:nil
                waitUntilDone:NO];
    }
}

- (void)stop {
    if ([[NSThread currentThread] isEqual:self]) {
        [super cancel];
    } else {
        // This call forces the runloop in main to spin allowing main to see that
        // the isCancelled flag has been set. Note that we explicitly want to send
        // it to the thread to process so it is added to the end of the queue of
        // blocks to be processed. 'stop' guarantees that all items in the queue
        // will be processed before it ends.
        [self performSelector:@selector(cancel)
                     onThread:self
                   withObject:nil
                waitUntilDone:YES];
        while (![self isFinished] || [self isExecuting]) {
            // Spin until the thread is really done.
            usleep(10);
        }
    }
}


@end
