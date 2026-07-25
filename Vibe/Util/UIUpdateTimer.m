//
//  UIUpdateTimer.m
//  Vibe
//

#import "UIUpdateTimer.h"

@implementation UIUpdateTimer {
    dispatch_source_t   _timer;
    // The dispatch source's actual state; wanted/windowVisible are the
    // intent. Reconciled by sync — unbalanced dispatch_resume/suspend traps,
    // hence the guard.
    BOOL                _running;
}

- (instancetype)initWithHz:(NSUInteger)hz handler:(dispatch_block_t)handler {
    self = [super init];
    if (self) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        // Leeway must be well under the interval, or the OS coalesces ticks
        // and the time label visibly skips seconds (worst on battery).
        // ~1/10th interval.
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / hz, NSEC_PER_SEC / hz / 10);
        dispatch_source_set_event_handler(_timer, handler);
        _running = NO; // sources are created suspended
    }
    return self;
}

- (void)dealloc {
    // Releasing a suspended dispatch source traps; the timer is created
    // suspended and stays suspended whenever _running is NO.
    if (!_running) {
        dispatch_resume(_timer);
    }
    dispatch_source_cancel(_timer);
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
