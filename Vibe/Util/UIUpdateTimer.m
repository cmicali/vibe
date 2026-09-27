//
//  UIUpdateTimer.m
//  Vibe
//

#import "UIUpdateTimer.h"

@implementation UIUpdateTimer {
    dispatch_source_t   _timer;
    // The source's actual state; wanted and windowVisible are the intent.
    BOOL                _running;
}

- (instancetype)initWithHz:(NSUInteger)hz handler:(dispatch_block_t)handler {
    self = [super init];
    if (self) {
        NSAssert(hz > 0, @"UIUpdateTimer needs a positive rate");
        hz = MAX(hz, (NSUInteger)1);
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        _hz = hz;
        // Due immediately, so a resume refreshes the UI at once.
        [self armFrom:DISPATCH_TIME_NOW];
        dispatch_source_set_event_handler(_timer, handler);
        _running = NO; // created suspended
    }
    return self;
}

// Legal on an active or suspended source: no resume/suspend bookkeeping.
- (void)armFrom:(dispatch_time_t)start {
    // A tenth of the interval: more lets the OS coalesce ticks and the time
    // label skip seconds.
    uint64_t interval = NSEC_PER_SEC / _hz;
    dispatch_source_set_timer(_timer, start, interval, interval / 10);
}

- (void)setHz:(NSUInteger)hz {
    if (hz == 0 || hz == _hz) {
        return;
    }
    _hz = hz;
    // A whole interval out: arming from now would fire at once, and the rate
    // changes in bursts during a resize drag.
    [self armFrom:dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / hz))];
}

- (void)dealloc {
    // Releasing a suspended source traps, so resume it — after cancelling,
    // so no handler can run in between.
    dispatch_source_cancel(_timer);
    if (!_running) {
        dispatch_resume(_timer);
    }
}

- (void)setWanted:(BOOL)wanted {
    _wanted = wanted;
    [self sync];
}

- (void)setWindowVisible:(BOOL)windowVisible {
    _windowVisible = windowVisible;
    [self sync];
}

- (void)sync {
    BOOL shouldRun = _wanted && _windowVisible;
    if (shouldRun == _running) {
        return;
    }
    if (shouldRun) {
        dispatch_resume(_timer);
    }
    else {
        dispatch_suspend(_timer);
    }
    _running = shouldRun;
}

@end
