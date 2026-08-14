//
//  OpenBurstCoalescer.m
//  Vibe
//

#import "OpenBurstCoalescer.h"

@implementation OpenBurstCoalescer {
    NSMutableArray<NSURL *> *_queue;
    BOOL _started;
    // A batch has already played, and further batches belong with it, so they
    // append rather than replace. Cleared when the quiet period elapses.
    BOOL _burstActive;
    // Superseded quiet-period timers become no-ops by generation check, since
    // a scheduled block cannot be recalled.
    NSUInteger _timerGeneration;
    NSTimeInterval _quietPeriod;
    OpenBurstScheduler _scheduler;
    OpenBurstSink _sink;
}

- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod sink:(OpenBurstSink)sink {
    return [self initWithQuietPeriod:quietPeriod
                           scheduler:^(NSTimeInterval delay, dispatch_block_t block) {
                               dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                              dispatch_get_main_queue(), block);
                           }
                                sink:sink];
}

- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod
                          scheduler:(OpenBurstScheduler)scheduler
                               sink:(OpenBurstSink)sink {
    self = [super init];
    if (self) {
        _queue = [NSMutableArray new];
        _quietPeriod = quietPeriod;
        _scheduler = [scheduler copy];
        _sink = [sink copy];
    }
    return self;
}

- (BOOL)startAndDrainQueue {
    _started = YES;
    if (_queue.count == 0) {
        return NO;
    }
    [self burstDrain];
    return YES;
}

- (void)openBurstURLs:(NSArray<NSURL *> *)urls {
    [_queue addObjectsFromArray:urls];
    [self burstDrain];
}

- (void)openReplacingURLs:(NSArray<NSURL *> *)urls {
    [_queue addObjectsFromArray:urls];
    _burstActive = NO; // a deliberate open ends any burst
    if (!_started || _queue.count == 0) {
        return; // pre-start: the launch drain picks the queue up
    }
    [self drainAppending:NO];
}

#pragma mark - Private

// The timer is touched before the started/empty guard, matching the burst
// entry point's original shape: even an event with nothing to drain extends
// the quiet period it belongs to.
- (void)burstDrain {
    [self touchQuietTimer];
    if (!_started || _queue.count == 0) {
        return; // pre-launch: startAndDrainQueue drains the queue
    }
    BOOL append = _burstActive;
    _burstActive = YES;
    [self drainAppending:append];
}

- (void)touchQuietTimer {
    NSUInteger generation = ++_timerGeneration;
    __weak __typeof(self) weakSelf = self;
    _scheduler(_quietPeriod, ^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_timerGeneration == generation) {
            strongSelf->_burstActive = NO;
        }
    });
}

- (void)drainAppending:(BOOL)append {
    NSArray<NSURL *> *urls = [_queue copy];
    [_queue removeAllObjects];
    _sink(urls, append);
}

@end
