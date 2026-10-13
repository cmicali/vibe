//
//  AudioWorkScheduler.m
//  Vibe
//

#import "AudioWorkScheduler.h"
#import "AudioWorkAdmissionRules.h"
#import <os/lock.h>

typedef NS_ENUM(NSInteger, VibeAudioWorkState) {
    VibeAudioWorkStatePending = 0,
    VibeAudioWorkStateRunning,
    VibeAudioWorkStateFinished,
    VibeAudioWorkStateCancelled,
    VibeAudioWorkStateRejected,
};

@interface VibeAudioWorkItem : NSObject
@property (nonatomic, copy, nullable) dispatch_block_t work;
@property (nonatomic, strong, nullable) dispatch_queue_t failureQueue;
@property (nonatomic, copy, nullable) void (^admissionFailure)(VibeAudioWorkAdmissionFailure failure);
@property (nonatomic) VibeAudioWorkState state;
@property (nonatomic) NSTimeInterval deadline;
@property (nonatomic) VibeAudioWorkAdmissionFailure rejection;
@end

@implementation VibeAudioWorkItem
@end

@interface AudioWorkScheduler ()
- (BOOL)cancelPendingItem:(VibeAudioWorkItem *)item;
@end

@interface AudioWorkToken ()
- (instancetype)initWithScheduler:(AudioWorkScheduler *)scheduler
                              item:(VibeAudioWorkItem *)item;
@property (nonatomic, weak) AudioWorkScheduler *scheduler;
@property (nonatomic, strong) VibeAudioWorkItem *item;
@end

@implementation AudioWorkToken

- (instancetype)initWithScheduler:(AudioWorkScheduler *)scheduler
                              item:(VibeAudioWorkItem *)item {
    self = [super init];
    if (self) {
        _scheduler = scheduler;
        _item = item;
    }
    return self;
}

- (BOOL)cancelIfPending {
    return [self.scheduler cancelPendingItem:self.item];
}

@end

@implementation AudioWorkScheduler {
    os_unfair_lock _lock;
    dispatch_queue_t _workerQueue;
    dispatch_queue_t _timerQueue;
    dispatch_source_t _expiryTimer;
    NSMutableArray<VibeAudioWorkItem *> *_pendingItems;
    NSUInteger _runningCount;
    NSUInteger _maximumRunningCount;
    NSUInteger _maximumPendingCount;
    NSTimeInterval _pendingGrace;
}

- (instancetype)initWithLabel:(NSString *)label
              qualityOfService:(qos_class_t)qualityOfService
            maximumRunningCount:(NSUInteger)maximumRunningCount
            maximumPendingCount:(NSUInteger)maximumPendingCount
                  pendingGrace:(NSTimeInterval)pendingGrace {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _maximumRunningCount = MAX(maximumRunningCount, 1);
        _maximumPendingCount = maximumPendingCount;
        _pendingGrace = MAX(pendingGrace, 0);
        _pendingItems = [NSMutableArray array];

        dispatch_queue_attr_t workerAttributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, qualityOfService, 0);
        _workerQueue = dispatch_queue_create(
                [[label stringByAppendingString:@".workers"] UTF8String], workerAttributes);
        _timerQueue = dispatch_queue_create(
                [[label stringByAppendingString:@".admission"] UTF8String], DISPATCH_QUEUE_SERIAL);
        _expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _timerQueue);
        dispatch_source_set_timer(_expiryTimer, DISPATCH_TIME_FOREVER,
                DISPATCH_TIME_FOREVER, 0);
        __weak AudioWorkScheduler *weakSelf = self;
        dispatch_source_set_event_handler(_expiryTimer, ^{
            [weakSelf expirePendingItems];
        });
        dispatch_resume(_expiryTimer);
    }
    return self;
}

- (AudioWorkToken *)submitWork:(dispatch_block_t)work
                   failureQueue:(dispatch_queue_t)failureQueue
              admissionFailure:(void (^)(VibeAudioWorkAdmissionFailure failure))admissionFailure {
    VibeAudioWorkItem *item = [[VibeAudioWorkItem alloc] init];
    item.work = work;
    item.failureQueue = failureQueue;
    item.admissionFailure = admissionFailure;
    AudioWorkToken *token = [[AudioWorkToken alloc] initWithScheduler:self item:item];

    NSMutableArray<VibeAudioWorkItem *> *expired = [NSMutableArray array];
    BOOL startNow = NO;
    BOOL rejectNow = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lock);
    [self collectExpiredItemsLockedAtTime:now into:expired];
    switch (VibeAudioWorkAdmission(_runningCount, _maximumRunningCount,
                                   _pendingItems.count, _maximumPendingCount)) {
        case VibeAudioWorkAdmissionStart:
            item.state = VibeAudioWorkStateRunning;
            _runningCount++;
            startNow = YES;
            break;
        case VibeAudioWorkAdmissionPark:
            item.state = VibeAudioWorkStatePending;
            item.deadline = now + _pendingGrace;
            [_pendingItems addObject:item];
            break;
        case VibeAudioWorkAdmissionExhausted:
            item.state = VibeAudioWorkStateRejected;
            item.rejection = VibeAudioWorkAdmissionFailurePendingLimit;
            rejectNow = YES;
            break;
    }
    [self rescheduleExpiryTimerLockedAtTime:now];
    os_unfair_lock_unlock(&_lock);

    [self deliverRejectedItems:expired];
    if (startNow) {
        [self dispatchItem:item];
    }
    else if (rejectNow) {
        [self deliverRejectedItems:@[item]];
    }
    return token;
}

// A resumed source released uncancelled leaks. The pending drain is
// unreachable today (a parked item implies a running one, whose block retains
// self), but a parked caller has no timeout of its own, so it stays.
- (void)dealloc {
    dispatch_source_cancel(_expiryTimer);
    NSArray<VibeAudioWorkItem *> *abandoned = nil;
    os_unfair_lock_lock(&_lock);
    abandoned = [_pendingItems copy];
    [_pendingItems removeAllObjects];
    for (VibeAudioWorkItem *item in abandoned) {
        item.state = VibeAudioWorkStateRejected;
        item.rejection = VibeAudioWorkAdmissionFailureWaitExpired;
    }
    os_unfair_lock_unlock(&_lock);
    [self deliverRejectedItems:abandoned];
}

- (BOOL)cancelPendingItem:(VibeAudioWorkItem *)item {
    if (!item) {
        return NO;
    }
    BOOL removed = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lock);
    if (item.state == VibeAudioWorkStatePending) {
        NSUInteger index = [_pendingItems indexOfObjectIdenticalTo:item];
        if (index != NSNotFound) {
            [_pendingItems removeObjectAtIndex:index];
            item.state = VibeAudioWorkStateCancelled;
            removed = YES;
            [self rescheduleExpiryTimerLockedAtTime:now];
        }
    }
    os_unfair_lock_unlock(&_lock);
    if (removed) {
        // Outside the lock: releasing the blocks runs their captures' deallocs.
        item.work = nil;
        item.failureQueue = nil;
        item.admissionFailure = nil;
    }
    return removed;
}

- (void)dispatchItem:(VibeAudioWorkItem *)item {
    dispatch_async(_workerQueue, ^{
        @autoreleasepool {
            dispatch_block_t work = item.work;
            if (work) {
                work();
            }
        }
        [self finishItem:item];
    });
}

- (void)finishItem:(VibeAudioWorkItem *)item {
    NSMutableArray<VibeAudioWorkItem *> *expired = [NSMutableArray array];
    NSMutableArray<VibeAudioWorkItem *> *toStart = [NSMutableArray array];
    BOOL finished = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lock);
    if (item.state == VibeAudioWorkStateRunning) {
        item.state = VibeAudioWorkStateFinished;
        finished = YES;
        if (_runningCount > 0) {
            _runningCount--;
        }
    }
    [self collectExpiredItemsLockedAtTime:now into:expired];
    while (_runningCount < _maximumRunningCount && _pendingItems.count > 0) {
        VibeAudioWorkItem *next = _pendingItems.firstObject;
        [_pendingItems removeObjectAtIndex:0];
        next.state = VibeAudioWorkStateRunning;
        _runningCount++;
        [toStart addObject:next];
    }
    [self rescheduleExpiryTimerLockedAtTime:now];
    os_unfair_lock_unlock(&_lock);

    if (finished) {
        item.work = nil;
        item.failureQueue = nil;
        item.admissionFailure = nil;
    }
    [self deliverRejectedItems:expired];
    for (VibeAudioWorkItem *next in toStart) {
        [self dispatchItem:next];
    }
}

- (void)expirePendingItems {
    NSMutableArray<VibeAudioWorkItem *> *expired = [NSMutableArray array];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lock);
    [self collectExpiredItemsLockedAtTime:now into:expired];
    [self rescheduleExpiryTimerLockedAtTime:now];
    os_unfair_lock_unlock(&_lock);
    [self deliverRejectedItems:expired];
}

// _lock held.
- (void)collectExpiredItemsLockedAtTime:(NSTimeInterval)now
                                    into:(NSMutableArray<VibeAudioWorkItem *> *)expired {
    for (NSInteger index = (NSInteger)_pendingItems.count - 1; index >= 0; index--) {
        VibeAudioWorkItem *item = _pendingItems[(NSUInteger)index];
        if (!VibeAudioWorkAdmissionExpired(now, item.deadline)) {
            continue;
        }
        [_pendingItems removeObjectAtIndex:(NSUInteger)index];
        item.state = VibeAudioWorkStateRejected;
        item.rejection = VibeAudioWorkAdmissionFailureWaitExpired;
        [expired addObject:item];
    }
}

// _lock held. One reusable timer, so cancel/retry churn enqueues no blocks.
- (void)rescheduleExpiryTimerLockedAtTime:(NSTimeInterval)now {
    if (_pendingItems.count == 0) {
        dispatch_source_set_timer(_expiryTimer, DISPATCH_TIME_FOREVER,
                DISPATCH_TIME_FOREVER, 0);
        return;
    }
    NSTimeInterval earliest = DBL_MAX;
    for (VibeAudioWorkItem *item in _pendingItems) {
        earliest = MIN(earliest, item.deadline);
    }
    NSTimeInterval delay = MAX(earliest - now, 0);
    dispatch_source_set_timer(_expiryTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
}

// Never inline: submitWork: callers sit on the serial queues their failure
// blocks touch.
- (void)deliverRejectedItems:(NSArray<VibeAudioWorkItem *> *)items {
    for (VibeAudioWorkItem *item in items) {
        dispatch_queue_t queue = item.failureQueue;
        void (^failure)(VibeAudioWorkAdmissionFailure) = item.admissionFailure;
        VibeAudioWorkAdmissionFailure reason = item.rejection;
        item.work = nil;
        item.failureQueue = nil;
        item.admissionFailure = nil;
        if (queue && failure) {
            dispatch_async(queue, ^{ failure(reason); });
        }
    }
}

@end
