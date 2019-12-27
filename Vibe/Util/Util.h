//
//  Util.h
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#pragma once

bool runWithTimeout(int timeoutSec, void (^block)(void)) {
    dispatch_semaphore_t mySemaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        block();
        dispatch_semaphore_signal(mySemaphore);
    });
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC));
    return dispatch_semaphore_wait(mySemaphore, timeout);
}
